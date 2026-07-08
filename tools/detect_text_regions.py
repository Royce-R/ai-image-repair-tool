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
import subprocess
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


def clamp(value: float, lower: float, upper: float) -> float:
    return max(lower, min(upper, value))


def clamp_box(
    left: float,
    top: float,
    right: float,
    bottom: float,
    *,
    image_width: int,
    image_height: int,
) -> tuple[float, float, float, float]:
    return (
        clamp(left, 0.0, float(image_width)),
        clamp(top, 0.0, float(image_height)),
        clamp(right, 0.0, float(image_width)),
        clamp(bottom, 0.0, float(image_height)),
    )


def rgb_to_hex(rgb: np.ndarray | tuple[int, int, int]) -> str:
    red, green, blue = [int(round(float(part))) for part in rgb[:3]]
    return f"#{red:02x}{green:02x}{blue:02x}"


def sample_median_rgb(pixels: np.ndarray, fallback: tuple[int, int, int]) -> tuple[int, int, int]:
    if pixels.size == 0:
        return fallback
    median = np.median(pixels[:, :3].astype(np.float32), axis=0)
    return tuple(int(round(float(part))) for part in median[:3])


def color_luma(rgb: tuple[int, int, int]) -> float:
    red, green, blue = rgb
    return 0.299 * red + 0.587 * green + 0.114 * blue


def hex_to_rgb(value: str, fallback: tuple[int, int, int]) -> tuple[int, int, int]:
    text = str(value or "").lstrip("#")
    if len(text) != 6:
        return fallback
    try:
        return int(text[0:2], 16), int(text[2:4], 16), int(text[4:6], 16)
    except ValueError:
        return fallback


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


def split_box_by_column_gaps(
    box: dict[str, float],
    ink_mask: np.ndarray,
) -> list[dict[str, float]]:
    height = box_height(box)
    width = box_width(box)
    if width < max(80.0, height * 4.0):
        return [box]

    x0 = int(max(0, np.floor(box["inkLeft"])))
    x1 = int(min(ink_mask.shape[1], np.ceil(box["inkRight"])))
    y0 = int(max(0, np.floor(box["inkTop"])))
    y1 = int(min(ink_mask.shape[0], np.ceil(box["inkBottom"])))
    if x1 <= x0 or y1 <= y0:
        return [box]

    region = ink_mask[y0:y1, x0:x1]
    column_has_ink = np.any(region, axis=0)
    min_gap = int(max(6, min(18, round(height * 0.55))))
    segments: list[tuple[int, int]] = []
    start = 0
    gap_start: int | None = None

    for index, has_ink in enumerate(column_has_ink.tolist()):
        if has_ink:
            if gap_start is not None:
                gap_width = index - gap_start
                if gap_width >= min_gap:
                    end = gap_start
                    if end - start >= 3:
                        segments.append((start, end))
                    start = index
                gap_start = None
        elif gap_start is None:
            gap_start = index

    if len(column_has_ink) - start >= 3:
        segments.append((start, len(column_has_ink)))

    if len(segments) <= 1:
        return [box]

    split_boxes: list[dict[str, float]] = []
    for start_x, end_x in segments:
        segment = region[:, start_x:end_x]
        ys, xs = np.nonzero(segment)
        if xs.size == 0 or ys.size == 0:
            continue
        ink_left = float(x0 + start_x + int(xs.min()))
        ink_right = float(x0 + start_x + int(xs.max()) + 1)
        ink_top = float(y0 + int(ys.min()))
        ink_bottom = float(y0 + int(ys.max()) + 1)
        ink_count = float(xs.size)
        pad = max(1.0, height * 0.15)
        split_boxes.append(
            {
                "left": max(box["left"], ink_left - pad),
                "top": max(box["top"], ink_top - pad * 0.5),
                "right": min(box["right"], ink_right + pad),
                "bottom": min(box["bottom"], ink_bottom + pad * 0.5),
                "inkLeft": ink_left,
                "inkTop": ink_top,
                "inkRight": ink_right,
                "inkBottom": ink_bottom,
                "inkCount": ink_count,
                "dilatedCount": ink_count,
            }
        )

    return split_boxes or [box]


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
            allowed_gap = max(merge_gap, max(box_height(existing), box_height(box)) * 0.35)
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


def styled_and_clamped(
    box: dict[str, float],
    *,
    rgba: np.ndarray,
    ink_mask: np.ndarray,
    image_width: int,
    image_height: int,
    pad_x: float,
    pad_y: float,
) -> dict[str, float]:
    ink_left, ink_top, ink_right, ink_bottom = clamp_box(
        box["inkLeft"] - pad_x,
        box["inkTop"] - pad_y,
        box["inkRight"] + pad_x,
        box["inkBottom"] + pad_y,
        image_width=image_width,
        image_height=image_height,
    )
    ink_width = max(1.0, ink_right - ink_left)
    ink_height = max(1.0, ink_bottom - ink_top)

    font_size = max(6.0, min(56.0, round(ink_height * 0.86, 1)))
    line_height = max(ink_height + 2.0, font_size * 1.16)
    text_top = clamp(
        ink_top - max(0.0, (line_height - ink_height) * 0.48),
        0.0,
        max(0.0, float(image_height) - line_height),
    )
    text_left = clamp(ink_left - max(1.0, font_size * 0.05), 0.0, float(image_width))
    text_right = clamp(ink_right + max(1.0, font_size * 0.05), text_left + 1.0, float(image_width))

    mask_pad_x = max(2.0, font_size * 0.08)
    mask_pad_y = max(1.0, font_size * 0.06)
    mask_left, mask_top, mask_right, mask_bottom = clamp_box(
        ink_left - mask_pad_x,
        ink_top - mask_pad_y,
        ink_right + mask_pad_x,
        ink_bottom + mask_pad_y,
        image_width=image_width,
        image_height=image_height,
    )

    x0, y0 = int(np.floor(mask_left)), int(np.floor(mask_top))
    x1, y1 = int(np.ceil(mask_right)), int(np.ceil(mask_bottom))
    region = rgba[y0:y1, x0:x1, :3]
    region_ink = ink_mask[y0:y1, x0:x1]
    foreground_pixels = region[region_ink]
    background_pixels = region[~region_ink]
    text_rgb = sample_median_rgb(foreground_pixels, (20, 20, 20))
    background_rgb = sample_median_rgb(background_pixels, (255, 255, 255))
    if color_luma(text_rgb) > 210 and color_luma(background_rgb) > 210:
        background_rgb = (255, 255, 255)

    char_count = max(1, min(24, int(round(ink_width / max(font_size * 1.1, 1.0)))))
    template_text = "字" * char_count
    bold = bool(font_size >= 17 or box["inkCount"] / max(ink_width * ink_height, 1.0) > 0.24)
    return {
        "left": round(text_left, 1),
        "top": round(text_top, 1),
        "width": round(text_right - text_left, 1),
        "height": round(line_height, 1),
        "mask": {
            "left": round(mask_left, 1),
            "top": round(mask_top, 1),
            "width": round(mask_right - mask_left, 1),
            "height": round(mask_bottom - mask_top, 1),
        },
        "ink": {
            "left": round(ink_left, 1),
            "top": round(ink_top, 1),
            "width": round(ink_width, 1),
            "height": round(ink_height, 1),
        },
        "style": {
            "textColor": rgb_to_hex(text_rgb),
            "backgroundColor": rgb_to_hex(background_rgb),
            "fontSize": font_size,
            "bold": bold,
            "alignment": "center",
            "templateText": template_text,
        },
        "fontSize": font_size,
        "inkDensity": round(box["inkCount"] / max((box_width(box) * box_height(box)), 1), 4),
    }


def is_probable_edit_region(box: dict[str, float], *, image_height: int) -> bool:
    style = box.get("style", {})
    text_color = str(style.get("textColor", "#000000")).lstrip("#")
    if len(text_color) != 6:
        return True
    red = int(text_color[0:2], 16)
    green = int(text_color[2:4], 16)
    blue = int(text_color[4:6], 16)
    chroma = max(red, green, blue) - min(red, green, blue)
    font_size = float(style.get("fontSize", box.get("fontSize", 0)))

    below_header = box["top"] > image_height * 0.20
    if below_header and font_size > 38:
        return False
    looks_like_colored_icon = chroma > 45 and font_size > 22 and box["width"] < 150
    looks_like_single_large_mark = font_size > 30 and box["width"] < 90 and below_header
    if below_header and (looks_like_colored_icon or looks_like_single_large_mark):
        return False
    return True


def write_cleaned_image(
    magick: str,
    rgba: np.ndarray,
    boxes: list[dict[str, float]],
    target: Path,
) -> None:
    height, width = rgba.shape[:2]
    cleaned = rgba.copy()

    for box in boxes:
        mask = box.get("mask") or box
        style = box.get("style", {})
        background = hex_to_rgb(str(style.get("backgroundColor", "#ffffff")), (255, 255, 255))
        x0 = int(clamp(np.floor(float(mask["left"])), 0, width))
        y0 = int(clamp(np.floor(float(mask["top"])), 0, height))
        x1 = int(clamp(np.ceil(float(mask["left"] + mask["width"])), 0, width))
        y1 = int(clamp(np.ceil(float(mask["top"] + mask["height"])), 0, height))
        if x1 <= x0 or y1 <= y0:
            continue
        cleaned[y0:y1, x0:x1, 0] = background[0]
        cleaned[y0:y1, x0:x1, 1] = background[1]
        cleaned[y0:y1, x0:x1, 2] = background[2]
        cleaned[y0:y1, x0:x1, 3] = 255

    target.parent.mkdir(parents=True, exist_ok=True)
    command = [
        magick,
        "-size",
        f"{width}x{height}",
        "-depth",
        "8",
        "rgba:-",
        str(target),
    ]
    try:
        subprocess.run(command, input=cleaned.tobytes(), check=True, capture_output=True)
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.decode("utf-8", "replace") if exc.stderr else ""
        raise RuntimeError(f"Failed to write cleaned image {target}: {stderr}") from exc


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
    split_boxes = [
        segment
        for box in raw_boxes
        for segment in split_box_by_column_gaps(box, ink)
    ]
    filtered = [
        box
        for box in split_boxes
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
        styled_and_clamped(
            box,
            rgba=rgba,
            ink_mask=ink,
            image_width=width,
            image_height=height,
            pad_x=pad_x,
            pad_y=pad_y,
        )
        for box in merged
    ]
    final_boxes = [
        box for box in final_boxes if is_probable_edit_region(box, image_height=height)
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
    parser.add_argument("--cleaned-dir", default=None)
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
    parser.add_argument("--merge-gap", type=float, default=8.0)
    parser.add_argument("--pad-x", type=float, default=2.0)
    parser.add_argument("--pad-y", type=float, default=1.0)
    parser.add_argument("--max-boxes", type=int, default=260)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    input_dir = Path(args.input_dir).resolve()
    output_json = Path(args.output_json).resolve()
    output_json.parent.mkdir(parents=True, exist_ok=True)
    cleaned_dir = Path(args.cleaned_dir).resolve() if args.cleaned_dir else output_json.parent / "cleaned"
    cleaned_dir.mkdir(parents=True, exist_ok=True)
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
        cleaned_path = cleaned_dir / f"{source.stem}.text_removed.png"
        write_cleaned_image(magick, rgba, boxes, cleaned_path)
        payload["images"].append(
            {
                "source": str(source),
                "cleanedSource": str(cleaned_path),
                "name": source.name,
                "stem": source.stem,
                "width": original_width,
                "height": original_height,
                "textBoxes": boxes,
            }
        )
        print(f"{source.name}: {len(boxes)} text box(es), cleaned={cleaned_path.name}")

    output_json.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print("Finished text-region detection.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
