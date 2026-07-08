from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET


NS = {
    "a": "http://schemas.openxmlformats.org/drawingml/2006/main",
    "p": "http://schemas.openxmlformats.org/presentationml/2006/main",
    "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
}

for prefix, uri in NS.items():
    ET.register_namespace(prefix, uri)


SLIDE_RE = re.compile(r"ppt/slides/slide(\d+)\.xml$")


def qname(prefix: str, tag: str) -> str:
    return f"{{{NS[prefix]}}}{tag}"


def bool_arg(value: str) -> bool:
    return value.lower() in {"1", "true", "yes", "y"}


def safe_name(value: str) -> str:
    return re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", value)


def slide_number(file_name: str) -> int:
    match = SLIDE_RE.match(file_name)
    if not match:
        return 0
    return int(match.group(1))


def c_nv_pr(element: ET.Element) -> ET.Element | None:
    return element.find(".//p:cNvPr", NS)


def rename_c_nv_pr(element: ET.Element, name: str, descr: str) -> None:
    props = c_nv_pr(element)
    if props is None:
        return
    props.set("name", name[:240])
    props.set("descr", descr[:1000])


def text_shapes(root: ET.Element) -> list[ET.Element]:
    shapes: list[ET.Element] = []
    for shape in root.findall(".//p:sp", NS):
        if shape.find("p:txBody", NS) is not None:
            shapes.append(shape)
    return shapes


def box_desc(index: int, box: dict[str, object]) -> str:
    return (
        f"Editable text placeholder {index:03d}; "
        f"detected at left={box.get('left')}, top={box.get('top')}, "
        f"width={box.get('width')}, height={box.get('height')}."
    )


def rename_reference_slide(data: bytes, image: dict[str, object]) -> bytes:
    root = ET.fromstring(data)
    stem = safe_name(str(image.get("stem", "image")))
    pictures = root.findall(".//p:pic", NS)
    if pictures:
        rename_c_nv_pr(
            pictures[0],
            "01_original_reference",
            f"Original source image for {stem}.",
        )
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def rename_repair_slide(data: bytes, image: dict[str, object], template_mode: str) -> bytes:
    root = ET.fromstring(data)
    stem = safe_name(str(image.get("stem", "image")))
    pictures = root.findall(".//p:pic", NS)
    if pictures:
        rename_c_nv_pr(
            pictures[0],
            "01_original_reference",
            f"Original source image for {stem}. Hide the cleaned layer to compare wording.",
        )
    if template_mode == "dual" and len(pictures) > 1:
        rename_c_nv_pr(
            pictures[1],
            "02_cleaned_text_removed",
            f"Text-removed base image for {stem}. Toggle this layer while editing.",
        )

    boxes = list(image.get("textBoxes", []))
    for index, shape in enumerate(text_shapes(root), start=1):
        box = boxes[index - 1] if index - 1 < len(boxes) and isinstance(boxes[index - 1], dict) else {}
        rename_c_nv_pr(shape, f"03_text_{index:03d}", box_desc(index, box))
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def planned_slides(images: list[dict[str, object]], reference_slides: bool) -> list[tuple[str, dict[str, object]]]:
    planned: list[tuple[str, dict[str, object]]] = []
    for image in images:
        if reference_slides:
            planned.append(("reference", image))
        planned.append(("repair", image))
    return planned


def rewrite_pptx(
    pptx_path: Path,
    images: list[dict[str, object]],
    *,
    reference_slides: bool,
    template_mode: str,
) -> None:
    if not pptx_path.exists():
        return

    planned = planned_slides(images, reference_slides)
    temp_fd, temp_name = tempfile.mkstemp(
        suffix=".pptx",
        prefix=f"{pptx_path.stem}.",
        dir=pptx_path.parent,
    )
    os.close(temp_fd)
    temp_path = Path(temp_name)

    changed = False
    try:
        with zipfile.ZipFile(pptx_path, "r") as source, zipfile.ZipFile(temp_path, "w") as target:
            slide_files = sorted(
                [item.filename for item in source.infolist() if SLIDE_RE.match(item.filename)],
                key=slide_number,
            )
            slide_plan = dict(zip(slide_files, planned))

            for item in source.infolist():
                data = source.read(item.filename)
                if item.filename in slide_plan:
                    kind, image = slide_plan[item.filename]
                    if kind == "reference":
                        data = rename_reference_slide(data, image)
                    else:
                        data = rename_repair_slide(data, image, template_mode)
                    changed = True
                target.writestr(item, data)

        if changed:
            os.replace(temp_path, pptx_path)
        else:
            temp_path.unlink(missing_ok=True)
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise


def find_image_by_stem(images: list[dict[str, object]], stem: str) -> dict[str, object] | None:
    for image in images:
        if safe_name(str(image.get("stem", ""))) == stem:
            return image
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Rename PPTX layers for PowerPoint Selection Pane editing.")
    parser.add_argument("--regions", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--reference-slides", default="false")
    parser.add_argument("--template-mode", default="dual")
    args = parser.parse_args()

    regions = json.loads(Path(args.regions).read_text(encoding="utf-8"))
    images = list(regions.get("images", []))
    output_dir = Path(args.output_dir)
    reference_slides = bool_arg(args.reference_slides)

    rewrite_pptx(
        output_dir / "combined_editable_text_layer.pptx",
        images,
        reference_slides=reference_slides,
        template_mode=args.template_mode,
    )

    per_image_dir = output_dir / "per_image"
    for pptx_path in per_image_dir.glob("*.editable_text_layer.pptx"):
        stem = pptx_path.name[: -len(".editable_text_layer.pptx")]
        image = find_image_by_stem(images, stem)
        if image is None:
            continue
        rewrite_pptx(
            pptx_path,
            [image],
            reference_slides=reference_slides,
            template_mode=args.template_mode,
        )

    print("PPTX layer names updated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
