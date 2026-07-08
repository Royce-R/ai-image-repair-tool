#!/usr/bin/env python3
"""
Batch-convert local raster images into SVG files.

The script writes two useful SVG variants:
  embedded/: visual-lossless SVG wrappers with the original raster image embedded
  traced/: quantized vector approximations made from filled SVG paths

Only NumPy and ImageMagick are required. ImageMagick handles image decoding, so
files with the wrong extension can still be processed.
"""

from __future__ import annotations

import argparse
import base64
import html
import mimetypes
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import numpy as np
except Exception as exc:  # pragma: no cover - this is a startup diagnostic
    print("ERROR: NumPy is required. Use a Python environment with numpy installed.")
    print(f"Import error: {exc}")
    raise SystemExit(2)


IMAGE_EXTENSIONS = {
    ".png",
    ".jpg",
    ".jpeg",
    ".webp",
    ".bmp",
    ".gif",
    ".tif",
    ".tiff",
}

MAGICK_CANDIDATES = (
    r"D:\ImageMagick-7.1.2-Q16-HDRI\magick.exe",
    r"C:\Program Files\ImageMagick-7.1.2-Q16-HDRI\magick.exe",
    r"C:\Program Files\ImageMagick-7.1.1-Q16-HDRI\magick.exe",
    r"C:\Program Files\ImageMagick-7.1.0-Q16-HDRI\magick.exe",
)

DIRECTION_DELTAS = {
    0: (1, 0),   # east
    1: (0, 1),   # south
    2: (-1, 0),  # west
    3: (0, -1),  # north
}


def run_command(args: list[str], *, text: bool = False) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            args,
            check=True,
            capture_output=True,
            text=text,
        )
    except FileNotFoundError as exc:
        raise RuntimeError(f"Command not found: {args[0]}") from exc
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr if isinstance(exc.stderr, str) else exc.stderr.decode("utf-8", "replace")
        stdout = exc.stdout if isinstance(exc.stdout, str) else exc.stdout.decode("utf-8", "replace")
        detail = (stderr or stdout or "").strip()
        command = " ".join(args)
        raise RuntimeError(f"Command failed: {command}\n{detail}") from exc


def find_magick(explicit: str | None) -> str:
    if explicit:
        path = Path(explicit)
        if path.exists():
            return str(path)
        found = shutil.which(explicit)
        if found:
            return found
        raise RuntimeError(f"ImageMagick executable was not found: {explicit}")

    found = shutil.which("magick")
    if found:
        return found

    for candidate in MAGICK_CANDIDATES:
        if Path(candidate).exists():
            return candidate

    raise RuntimeError(
        "ImageMagick 'magick' was not found. Install ImageMagick or pass --magick."
    )


def image_files(input_dir: Path, extensions: set[str]) -> list[Path]:
    files = [
        path
        for path in input_dir.iterdir()
        if path.is_file() and path.suffix.lower() in extensions
    ]
    return sorted(files, key=lambda item: item.name.lower())


def guess_mime(path: Path, data: bytes) -> str:
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"GIF87a") or data.startswith(b"GIF89a"):
        return "image/gif"
    if data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        return "image/webp"
    if data.startswith(b"BM"):
        return "image/bmp"
    guessed, _ = mimetypes.guess_type(path.name)
    return guessed or "application/octet-stream"


def identify_size(magick: str, path: Path) -> tuple[int, int]:
    result = run_command(
        [magick, "identify", "-quiet", "-format", "%w %h", str(path)],
        text=True,
    )
    width_text, height_text = result.stdout.strip().split()[:2]
    return int(width_text), int(height_text)


def magick_ops(path: Path, max_size: int, colors: int, dither: bool) -> list[str]:
    ops = [str(path), "-auto-orient"]
    if max_size > 0:
        ops.extend(["-resize", f"{max_size}x{max_size}>"])
    if colors > 0:
        if not dither:
            ops.append("+dither")
        ops.extend(["-colors", str(colors)])
    return ops


def load_rgba(
    magick: str,
    path: Path,
    *,
    max_size: int,
    colors: int,
    dither: bool,
) -> tuple[np.ndarray, tuple[int, int]]:
    ops = magick_ops(path, max_size, colors, dither)
    size_result = run_command([magick, *ops, "-format", "%w %h", "info:"], text=True)
    width_text, height_text = size_result.stdout.strip().split()[:2]
    width, height = int(width_text), int(height_text)

    raw = run_command([magick, *ops, "-depth", "8", "rgba:-"]).stdout
    pixels = np.frombuffer(raw, dtype=np.uint8)
    expected = width * height * 4
    if pixels.size != expected:
        raise RuntimeError(
            f"Unexpected pixel buffer size for {path.name}: got {pixels.size}, expected {expected}"
        )
    return pixels.reshape((height, width, 4)), (width, height)


def color_to_hex(color: tuple[int, int, int, int]) -> str:
    red, green, blue, _alpha = color
    return f"#{red:02x}{green:02x}{blue:02x}"


def color_attrs(color: tuple[int, int, int, int]) -> str:
    alpha = color[3]
    attrs = [f'fill="{color_to_hex(color)}"']
    if alpha < 255:
        attrs.append(f'fill-opacity="{alpha / 255:.3f}"')
    attrs.append('fill-rule="evenodd"')
    return " ".join(attrs)


def collect_palette(rgba: np.ndarray, alpha_threshold: int) -> list[tuple[tuple[int, int, int, int], int]]:
    flat = rgba.reshape((-1, 4))
    visible = flat[:, 3] > alpha_threshold
    if not np.any(visible):
        return []
    colors, counts = np.unique(flat[visible], axis=0, return_counts=True)
    palette = [
        (tuple(int(part) for part in color), int(count))
        for color, count in zip(colors, counts)
    ]
    palette.sort(key=lambda item: item[1], reverse=True)
    return palette


def key_to_point(key: int, row_stride: int) -> tuple[int, int]:
    return key % row_stride, key // row_stride


def polygon_area(points: list[tuple[int, int]]) -> float:
    if len(points) < 4:
        return 0.0
    if points[0] == points[-1]:
        points = points[:-1]
    area = 0
    for index, (x1, y1) in enumerate(points):
        x2, y2 = points[(index + 1) % len(points)]
        area += x1 * y2 - x2 * y1
    return area / 2.0


def simplify_closed_points(points: list[tuple[int, int]]) -> list[tuple[int, int]]:
    if len(points) < 4:
        return []

    if points[0] == points[-1]:
        points = points[:-1]

    deduped: list[tuple[int, int]] = []
    for point in points:
        if not deduped or deduped[-1] != point:
            deduped.append(point)

    if len(deduped) < 3:
        return []

    simplified: list[tuple[int, int]] = []
    count = len(deduped)
    for index, current in enumerate(deduped):
        previous = deduped[index - 1]
        next_point = deduped[(index + 1) % count]
        same_x = previous[0] == current[0] == next_point[0]
        same_y = previous[1] == current[1] == next_point[1]
        if same_x or same_y:
            continue
        simplified.append(current)

    if len(simplified) < 3:
        return []
    simplified.append(simplified[0])
    return simplified


def format_path(points: list[tuple[int, int]]) -> str:
    if not points:
        return ""
    closed = points[0] == points[-1]
    drawable = points[:-1] if closed else points
    start_x, start_y = drawable[0]
    commands = [f"M{start_x} {start_y}"]
    current_x, current_y = start_x, start_y
    for next_x, next_y in drawable[1:]:
        if next_x == current_x:
            commands.append(f"V{next_y}")
        elif next_y == current_y:
            commands.append(f"H{next_x}")
        else:
            commands.append(f"L{next_x} {next_y}")
        current_x, current_y = next_x, next_y
    commands.append("Z")
    return " ".join(commands)


def add_edge(edge_set: set[int], out_map: dict[int, int], key: int, direction: int) -> None:
    edge_id = key * 4 + direction
    edge_set.add(edge_id)
    out_map[key] = out_map.get(key, 0) | (1 << direction)


def build_edges(mask: np.ndarray) -> tuple[set[int], dict[int, int], int]:
    height, width = mask.shape
    row_stride = width + 1
    edge_set: set[int] = set()
    out_map: dict[int, int] = {}

    north = np.empty_like(mask, dtype=bool)
    north[0, :] = mask[0, :]
    north[1:, :] = mask[1:, :] & ~mask[:-1, :]
    ys, xs = np.nonzero(north)
    for y, x in zip(ys.tolist(), xs.tolist()):
        add_edge(edge_set, out_map, y * row_stride + x, 0)

    east = np.empty_like(mask, dtype=bool)
    east[:, -1] = mask[:, -1]
    east[:, :-1] = mask[:, :-1] & ~mask[:, 1:]
    ys, xs = np.nonzero(east)
    for y, x in zip(ys.tolist(), xs.tolist()):
        add_edge(edge_set, out_map, y * row_stride + x + 1, 1)

    south = np.empty_like(mask, dtype=bool)
    south[-1, :] = mask[-1, :]
    south[:-1, :] = mask[:-1, :] & ~mask[1:, :]
    ys, xs = np.nonzero(south)
    for y, x in zip(ys.tolist(), xs.tolist()):
        add_edge(edge_set, out_map, (y + 1) * row_stride + x + 1, 2)

    west = np.empty_like(mask, dtype=bool)
    west[:, 0] = mask[:, 0]
    west[:, 1:] = mask[:, 1:] & ~mask[:, :-1]
    ys, xs = np.nonzero(west)
    for y, x in zip(ys.tolist(), xs.tolist()):
        add_edge(edge_set, out_map, (y + 1) * row_stride + x, 3)

    return edge_set, out_map, row_stride


def trace_mask(
    mask: np.ndarray,
    *,
    min_area: float,
    max_paths: int,
) -> tuple[list[str], dict[str, int]]:
    edge_set, _out_map, row_stride = build_edges(mask)
    if not edge_set:
        return [], {"paths": 0, "dropped_small": 0, "dropped_limit": 0}

    used: set[int] = set()
    candidates: list[tuple[float, str]] = []
    dropped_small = 0
    deltas = {
        direction: dy * row_stride + dx
        for direction, (dx, dy) in DIRECTION_DELTAS.items()
    }

    for first_edge in list(edge_set):
        if first_edge in used:
            continue

        current_key, current_direction = divmod(first_edge, 4)
        start_key = current_key
        points = [key_to_point(current_key, row_stride)]

        for _step in range(len(edge_set) + 4):
            edge_id = current_key * 4 + current_direction
            if edge_id in used or edge_id not in edge_set:
                break
            used.add(edge_id)

            current_key += deltas[current_direction]
            points.append(key_to_point(current_key, row_stride))

            if current_key == start_key:
                break

            next_direction = None
            for candidate_direction in (
                (current_direction + 1) & 3,
                current_direction,
                (current_direction + 3) & 3,
                (current_direction + 2) & 3,
            ):
                candidate_edge = current_key * 4 + candidate_direction
                if candidate_edge in edge_set and candidate_edge not in used:
                    next_direction = candidate_direction
                    break

            if next_direction is None:
                break
            current_direction = next_direction

        if len(points) < 4 or points[0] != points[-1]:
            continue

        simplified = simplify_closed_points(points)
        area = abs(polygon_area(simplified))
        if area < min_area:
            dropped_small += 1
            continue

        path = format_path(simplified)
        if path:
            candidates.append((area, path))

    candidates.sort(key=lambda item: item[0], reverse=True)
    dropped_limit = 0
    if max_paths > 0 and len(candidates) > max_paths:
        dropped_limit = len(candidates) - max_paths
        candidates = candidates[:max_paths]

    return [path for _area, path in candidates], {
        "paths": len(candidates),
        "dropped_small": dropped_small,
        "dropped_limit": dropped_limit,
    }


def write_embedded_svg(magick: str, source: Path, target: Path) -> None:
    width, height = identify_size(magick, source)
    data = source.read_bytes()
    mime = guess_mime(source, data)
    encoded = base64.b64encode(data).decode("ascii")
    title = html.escape(source.name)
    svg = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img">\n'
        f'  <title>{title}</title>\n'
        f'  <image width="{width}" height="{height}" href="data:{mime};base64,{encoded}" />\n'
        "</svg>\n"
    )
    target.write_text(svg, encoding="utf-8")


def write_traced_svg(
    source: Path,
    target: Path,
    rgba: np.ndarray,
    original_size: tuple[int, int],
    *,
    alpha_threshold: int,
    background: str,
    min_area: float,
    max_paths_per_color: int,
) -> dict[str, int]:
    height, width = rgba.shape[:2]
    original_width, original_height = original_size
    palette = collect_palette(rgba, alpha_threshold)
    title = html.escape(source.name)

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{original_width}" '
            f'height="{original_height}" viewBox="0 0 {width} {height}" role="img" '
            'shape-rendering="geometricPrecision">'
        ),
        f"  <title>{title}</title>",
        "  <metadata>",
        f"    source={html.escape(str(source))}",
        f"    trace_size={width}x{height}",
        f"    visible_colors={len(palette)}",
        "  </metadata>",
    ]

    if not palette:
        lines.append("</svg>")
        target.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return {"colors": 0, "paths": 0, "dropped_small": 0, "dropped_limit": 0}

    background_color = palette[0][0] if background == "auto" else None
    if background_color is not None:
        lines.append(
            f'  <rect width="{width}" height="{height}" {color_attrs(background_color)} />'
        )

    total_paths = 0
    total_dropped_small = 0
    total_dropped_limit = 0

    for color, _count in palette:
        if color == background_color:
            continue
        color_array = np.array(color, dtype=np.uint8)
        mask = np.all(rgba == color_array, axis=2)
        subpaths, stats = trace_mask(
            mask,
            min_area=min_area,
            max_paths=max_paths_per_color,
        )
        total_paths += stats["paths"]
        total_dropped_small += stats["dropped_small"]
        total_dropped_limit += stats["dropped_limit"]

        if not subpaths:
            continue

        path_data = " ".join(subpaths)
        lines.append(f'  <path {color_attrs(color)} d="{path_data}" />')

    lines.append("</svg>")
    target.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return {
        "colors": len(palette),
        "paths": total_paths,
        "dropped_small": total_dropped_small,
        "dropped_limit": total_dropped_limit,
    }


def render_preview(magick: str, svg_path: Path, png_path: Path) -> None:
    run_command(
        [
            magick,
            str(svg_path),
            "-background",
            "white",
            "-alpha",
            "remove",
            str(png_path),
        ]
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert local AI/raster images to embedded and traced SVG files."
    )
    parser.add_argument("--input-dir", default="resource", help="Directory with source images.")
    parser.add_argument("--output-dir", default="svg_output", help="Output directory.")
    parser.add_argument(
        "--mode",
        choices=("both", "embedded", "trace"),
        default="both",
        help="Which SVG variant to generate.",
    )
    parser.add_argument("--colors", type=int, default=64, help="Color count for traced SVG.")
    parser.add_argument(
        "--max-size",
        type=int,
        default=1400,
        help="Longest traced side in pixels. Use 0 to keep original size.",
    )
    parser.add_argument(
        "--min-area",
        type=float,
        default=1.0,
        help="Drop traced regions smaller than this area in trace pixels.",
    )
    parser.add_argument(
        "--max-paths-per-color",
        type=int,
        default=4000,
        help="Cap path count per color. Use 0 for no cap.",
    )
    parser.add_argument(
        "--alpha-threshold",
        type=int,
        default=8,
        help="Pixels with alpha at or below this value are treated as transparent.",
    )
    parser.add_argument(
        "--background",
        choices=("auto", "none"),
        default="auto",
        help="Use the largest visible color as a background rect, or trace every color.",
    )
    parser.add_argument("--dither", action="store_true", help="Allow ImageMagick color dithering.")
    parser.add_argument("--preview", action="store_true", help="Render PNG previews of traced SVGs.")
    parser.add_argument("--magick", default=None, help="Path to ImageMagick magick executable.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    input_dir = Path(args.input_dir).resolve()
    output_dir = Path(args.output_dir).resolve()
    if not input_dir.exists():
        print(f"ERROR: input directory does not exist: {input_dir}")
        return 2

    magick = find_magick(args.magick)
    sources = image_files(input_dir, IMAGE_EXTENSIONS)
    if not sources:
        print(f"No image files found in {input_dir}")
        return 0

    embedded_dir = output_dir / "embedded"
    traced_dir = output_dir / "traced"
    preview_dir = output_dir / "preview_png"
    if args.mode in ("both", "embedded"):
        embedded_dir.mkdir(parents=True, exist_ok=True)
    if args.mode in ("both", "trace"):
        traced_dir.mkdir(parents=True, exist_ok=True)
    if args.preview:
        preview_dir.mkdir(parents=True, exist_ok=True)

    print(f"Input:  {input_dir}")
    print(f"Output: {output_dir}")
    print(f"Magick: {magick}")
    print(f"Images: {len(sources)}")

    failures = 0
    for source in sources:
        stem = source.stem
        print(f"\n== {source.name} ==")
        try:
            original_size = identify_size(magick, source)

            if args.mode in ("both", "embedded"):
                embedded_svg = embedded_dir / f"{stem}.embedded.svg"
                write_embedded_svg(magick, source, embedded_svg)
                print(f"embedded: {embedded_svg.relative_to(output_dir)}")

            if args.mode in ("both", "trace"):
                rgba, trace_size = load_rgba(
                    magick,
                    source,
                    max_size=args.max_size,
                    colors=args.colors,
                    dither=args.dither,
                )
                traced_svg = traced_dir / f"{stem}.traced.svg"
                stats = write_traced_svg(
                    source,
                    traced_svg,
                    rgba,
                    original_size,
                    alpha_threshold=args.alpha_threshold,
                    background=args.background,
                    min_area=args.min_area,
                    max_paths_per_color=args.max_paths_per_color,
                )
                print(
                    "traced:   "
                    f"{traced_svg.relative_to(output_dir)} "
                    f"size={trace_size[0]}x{trace_size[1]} "
                    f"colors={stats['colors']} paths={stats['paths']} "
                    f"drop_small={stats['dropped_small']} drop_limit={stats['dropped_limit']}"
                )

                if args.preview:
                    preview_png = preview_dir / f"{stem}.traced.png"
                    render_preview(magick, traced_svg, preview_png)
                    print(f"preview:  {preview_png.relative_to(output_dir)}")

        except Exception as exc:
            failures += 1
            print(f"ERROR: {source.name}: {exc}")

    if failures:
        print(f"\nFinished with {failures} failure(s).")
        return 1

    print("\nFinished successfully.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
