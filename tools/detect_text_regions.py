#!/usr/bin/env python3
"""
Detect likely text-line regions in raster images without OCR.

The output is a JSON file consumed by create_editable_text_pptx.mjs. The goal is
not perfect text recognition; it is to create editable PowerPoint text boxes in
the right places so a human can manually repair AI-generated labels.
"""

from __future__ import annotations

import argparse
import json
from collections import deque
from pathlib import Path

import numpy as np

from raster_to_svg import IMAGE_EXTENSIONS, find_magick, identify_size, image_files, load_rgba


def dilate(mask: np.ndarray, radius_x: int, radius_y: int) -> np.ndarray:
    result = mask.copy()
    source = mask

    if radius_x > 0:
        horizontal = source.copy()
        for offset in range(1, radius_x + 1):
            horizontal[:, offset:] |= source[:, :-offset]
            horizontal[:, :-offset] |= source[:, offset:]
        result = horizontal

    if radius_y > 0:
        vertical_source = result
        vertical = vertical_source.copy()
        for offset in range(1, radius_y + 1):
            vertical[offset:, :] |= vertical_source[:-offset, :]
            vertical[:-offset, :] |= vertical_source[offset:, :]
        result = vertical

    return result


def probable_ink_mask(
    rgba: np.ndarray,
    *,
    dark_threshold: int,
    colored_threshold: int,
    min_chroma: int,
    alpha_threshold: int,
) -> np.ndarray:
    rgb = rgba[:, :, :3].astype(np.int16)
    red = rgb[:, :, 0]
    green = rgb[:, :, 1]
    blue = rgb[:, :, 2]
    luma = 0.299 * red + 0.587 * green + 0.114 * blue
    max_channel = rgb.max(axis=2)
    min_channel = rgb.min(axis=2)
    chroma = max_channel - min_channel
    alpha = rgba[:, :, 3] > alpha_threshold

    dark = luma < dark_threshold
    colored_dark = (luma < colored_threshold) & (chroma > min_chroma) & (min_channel < 175)
    return alpha & (dark | colored_dark)


def component_boxes(group_mask: np.ndarray, ink_mask: np.ndarray) -> list[dict[str, float]]:
    height, width = group_mask.shape
    visited = np.zeros_like(group_mask, dtype=bool)
    boxes: list[dict[str, float]] = []

    ys, xs = np.nonzero(group_mask)
    for start_y, start_x in zip(ys.tolist(), xs.tolist()):
        if visited[start_y, start_x]:
            continue

        queue: deque[tuple[int, int]] = deque([(start_y, start_x)])
        visited[start_y, start_x] = True

        min_x = max_x = start_x
        min_y = max_y = start_y
        ink_min_x = width
        ink_max_x = -1
        ink_min_y = height
        ink_max_y = -1
        dilated_count = 0
        ink_count = 0

        while queue:
            y, x = queue.popleft()
            dilated_count += 1
            if x < min_x:
                min_x = x
            if x > max_x:
                max_x = x
            if y < min_y:
                min_y = y
            if y > max_y:
                max_y = y

            if ink_mask[y, x]:
                ink_count += 1
                if x < ink_min_x:
                    ink_min_x = x
                if x > ink_max_x:
                    ink_max_x = x
                if y < ink_min_y:
                    ink_min_y = y
                if y > ink_max_y:
                    ink_max_y = y

            y0 = max(0, y - 1)
            y1 = min(height - 1, y + 1)
            x0 = max(0, x - 1)
            x1 = min(width - 1, x + 1)
            for next_y in range(y0, y1 + 1):
                for next_x in range(x0, x1 + 1):
                    if not visited[next_y, next_x] and group_mask[next_y, next_x]:
                        visited[next_y, next_x] = True
                        queue.append((next_y, next_x))

        if ink_count == 0:
            continue

        boxes.append(
            {
                "left": float(min_x),
                "top": float(min_y),
                "right": float(max_x + 1),
                "bottom": float(max_y + 1),
                "inkLeft": float(ink_min_x),
                "inkTop": float(ink_min_y),
                "inkRight": float(ink_max_x + 1),
                "inkBottom": float(ink_max_y + 1),
                "inkCount": float(ink_count),
                "dilatedCount": float(dilated_count),
            }
        )

    return boxes


def box_width(box: dict[str, float]) -> float:
    return box["right"] - box["left"]


def box_height(box: dict[str, float]) -> float:
    return box["bottom"] - box["top"]


def is_probable_text_box(
    box: dict[str, float],
    *,
    image_width: int,
    image_height: int,
    min_width: float,
    min_height: float,
    max_height: float,
) -> bool:
    width = box_width(box)
    height = box_height(box)
    area = width * height
    if width < min_width or height < min_height:
        return False
    if height > max_height:
        return False
    if area > image_width * image_height * 0.08 and height > image_height * 0.08:
        return False
    if height > 42 and box["top"] > image_height * 0.16 and width > 70:
        return False

    aspect = width / max(height, 1)
    if aspect < 0.55:
        return False
    if height / max(width, 1) > 4.0 and height > 36:
        return False

    ink_density = box["inkCount"] / max(area, 1)
    if ink_density > 0.72 and area > 500:
        return False
    if box["inkCount"] < 5:
        return False

    return True


def vertical_overlap(a: dict[str, float], b: dict[str, float]) -> float:
    overlap = min(a["bottom"], b["bottom"]) - max(a["top"], b["top"])
    if overlap <= 0:
        return 0.0
    return overlap / max(1.0, min(box_height(a), box_height(b)))


def merge_two(a: dict[str, float], b: dict[str, float]) -> dict[str, float]:
    merged = {
        "left": min(a["left"], b["left"]),
        "top": min(a["top"], b["top"]),
        "right": max(a["right"], b["right"]),
        "bottom": max(a["bottom"], b["bottom"]),
        "inkLeft": min(a["inkLeft"], b["inkLeft"]),
        "inkTop": min(a["inkTop"], b["inkTop"]),
        "inkRight": max(a["inkRight"], b["inkRight"]),
        "inkBottom": max(a["inkBottom"], b["inkBottom"]),
        "inkCount": a["inkCount"] + b["inkCount"],
        "dilatedCount": a["dilatedCount"] + b["dilatedCount"],
    }
    return merged


def merge_text_boxes(boxes: list[dict[str, float]], *, merge_gap: float) -> list[dict[str, float]]:
    ordered = sorted(boxes, key=lambda item: (item["top"], item["left"]))
    merged: list[dict[str, float]] = []

    for box in ordered:
        target_index = None
        for index, existing in enumerate(merged):
            same_line = vertical_overlap(existing, box) >= 0.42
            center_delta = abs(
                ((existing["top"] + existing["bottom"]) / 2)
                - ((box["top"] + box["bottom"]) / 2)
            )
            same_baseline = center_delta <= max(box_height(existing), box_height(box)) * 0.45
            gap = box["left"] - existing["right"]
            reverse_gap = existing["left"] - box["right"]
            allowed_gap = max(merge_gap, max(box_height(existing), box_height(box)) * 0.75)
            near = (0 <= gap <= allowed_gap) or (0 <= reverse_gap <= allowed_gap)
            if (same_line or same_baseline) and near:
                target_index = index
                break

        if target_index is None:
            merged.append(box)
        else:
            merged[target_index] = merge_two(merged[target_index], box)

    return sorted(merged, key=lambda item: (item["top"], item["left"]))


def drop_contained_boxes(boxes: list[dict[str, float]]) -> list[dict[str, float]]:
    ordered = sorted(boxes, key=lambda item: box_width(item) * box_height(item), reverse=True)
    kept: list[dict[str, float]] = []

    for box in ordered:
        box_area = box_width(box) * box_height(box)
        contained = False
        for larger in kept:
            larger_area = box_width(larger) * box_height(larger)
            if larger_area < box_area * 2.4:
                continue
            inside = (
                box["left"] >= larger["left"] - 2
                and box["right"] <= larger["right"] + 2
                and box["top"] >= larger["top"] - 2
                and box["bottom"] <= larger["bottom"] + 2
            )
            if inside:
                contained = True
                break
        if not contained:
            kept.append(box)

    return sorted(kept, key=lambda item: (item["top"], item["left"]))


def padded_and_clamped(
    box: dict[str, float],
    *,
    image_width: int,
    image_height: int,
    pad_x: float,
    pad_y: float,
) -> dict[str, float]:
    left = max(0.0, box["left"] - pad_x)
    top = max(0.0, box["top"] - pad_y)
    right = min(float(image_width), box["right"] + pad_x)
    bottom = min(float(image_height), box["bottom"] + pad_y)
    height = bottom - top
    font_size = max(7.0, min(52.0, round(height * 0.74, 1)))
    return {
        "left": round(left, 1),
        "top": round(top, 1),
        "width": round(right - left, 1),
        "height": round(height, 1),
        "fontSize": font_size,
        "inkDensity": round(box["inkCount"] / max((box_width(box) * box_height(box)), 1), 4),
    }


def detect_boxes(
    rgba: np.ndarray,
    *,
    dark_threshold: int,
    colored_threshold: int,
    min_chroma: int,
    alpha_threshold: int,
    line_gap: int,
    vertical_gap: int,
    min_width: float,
    min_height: float,
    max_height: float,
    merge_gap: float,
    pad_x: float,
    pad_y: float,
    max_boxes: int,
) -> list[dict[str, float]]:
    height, width = rgba.shape[:2]
    ink = probable_ink_mask(
        rgba,
        dark_threshold=dark_threshold,
        colored_threshold=colored_threshold,
        min_chroma=min_chroma,
        alpha_threshold=alpha_threshold,
    )
    grouped = dilate(ink, line_gap, vertical_gap)
    raw_boxes = component_boxes(grouped, ink)
    filtered = [
        box
        for box in raw_boxes
        if is_probable_text_box(
            box,
            image_width=width,
            image_height=height,
            min_width=min_width,
            min_height=min_height,
            max_height=max_height,
        )
    ]
    merged = drop_contained_boxes(merge_text_boxes(filtered, merge_gap=merge_gap))
    final_boxes = [
        padded_and_clamped(
            box,
            image_width=width,
            image_height=height,
            pad_x=pad_x,
            pad_y=pad_y,
        )
        for box in merged
    ]

    if max_boxes > 0 and len(final_boxes) > max_boxes:
        # Prefer larger text lines when the detector is too permissive.
        final_boxes = sorted(
            final_boxes,
            key=lambda item: item["width"] * item["height"],
            reverse=True,
        )[:max_boxes]
        final_boxes.sort(key=lambda item: (item["top"], item["left"]))

    for index, box in enumerate(final_boxes, start=1):
        box["id"] = f"text_{index:03d}"
    return final_boxes


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Detect editable text-box positions for PPT repair.")
    parser.add_argument("--input-dir", default="resource")
    parser.add_argument("--output-json", default="ppt_editable_output/text_regions.json")
    parser.add_argument("--magick", default=None)
    parser.add_argument("--dark-threshold", type=int, default=132)
    parser.add_argument("--colored-threshold", type=int, default=168)
    parser.add_argument("--min-chroma", type=int, default=42)
    parser.add_argument("--alpha-threshold", type=int, default=8)
    parser.add_argument("--line-gap", type=int, default=6)
    parser.add_argument("--vertical-gap", type=int, default=1)
    parser.add_argument("--min-width", type=float, default=8.0)
    parser.add_argument("--min-height", type=float, default=6.0)
    parser.add_argument("--max-height", type=float, default=92.0)
    parser.add_argument("--merge-gap", type=float, default=16.0)
    parser.add_argument("--pad-x", type=float, default=2.0)
    parser.add_argument("--pad-y", type=float, default=1.0)
    parser.add_argument("--max-boxes", type=int, default=260)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    input_dir = Path(args.input_dir).resolve()
    output_json = Path(args.output_json).resolve()
    output_json.parent.mkdir(parents=True, exist_ok=True)
    magick = find_magick(args.magick)
    sources = image_files(input_dir, IMAGE_EXTENSIONS)

    payload = {
        "version": 1,
        "sourceDir": str(input_dir),
        "detector": {
            "darkThreshold": args.dark_threshold,
            "coloredThreshold": args.colored_threshold,
            "lineGap": args.line_gap,
            "verticalGap": args.vertical_gap,
            "note": "Regions are likely text lines for manual editing; no OCR text is included.",
        },
        "images": [],
    }

    print(f"Input:  {input_dir}")
    print(f"Output: {output_json}")
    print(f"Magick: {magick}")

    for source in sources:
        original_width, original_height = identify_size(magick, source)
        rgba, _trace_size = load_rgba(
            magick,
            source,
            max_size=0,
            colors=0,
            dither=False,
        )
        boxes = detect_boxes(
            rgba,
            dark_threshold=args.dark_threshold,
            colored_threshold=args.colored_threshold,
            min_chroma=args.min_chroma,
            alpha_threshold=args.alpha_threshold,
            line_gap=args.line_gap,
            vertical_gap=args.vertical_gap,
            min_width=args.min_width,
            min_height=args.min_height,
            max_height=args.max_height,
            merge_gap=args.merge_gap,
            pad_x=args.pad_x,
            pad_y=args.pad_y,
            max_boxes=args.max_boxes,
        )
        payload["images"].append(
            {
                "source": str(source),
                "name": source.name,
                "stem": source.stem,
                "width": original_width,
                "height": original_height,
                "textBoxes": boxes,
            }
        )
        print(f"{source.name}: {len(boxes)} text box(es)")

    output_json.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print("Finished text-region detection.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
