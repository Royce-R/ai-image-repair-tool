# Local Raster-to-SVG and Editable PowerPoint Workflow

## Best option for PowerPoint repair

For manual PowerPoint editing, use the editable PPTX workflow:

```powershell
.\convert_images_to_editable_ppt.ps1
```

It creates:

- `ppt_editable_output/combined_editable_text_layer.pptx`: one deck containing all images.
- `ppt_editable_output/per_image/*.editable_text_layer.pptx`: one exact-size PPTX per source image.
- `ppt_editable_output/text_regions.json`: detected text-line boxes.
- `ppt_editable_output/preview/*`: rendered previews.

Each slide keeps the original image as a full-size visual reference and places
PowerPoint-native editable text boxes over likely text lines. No OCR text is
inserted by default; the boxes are meant as manual repair targets.

If the detector misses text, try wider grouping:

```powershell
.\convert_images_to_editable_ppt.ps1 -LineGap 10 -VerticalGap 2
```

If it creates too many boxes, make detection stricter:

```powershell
.\convert_images_to_editable_ppt.ps1 -DarkThreshold 115 -ColoredThreshold 150 -MaxBoxes 180
```

To make every editable box show a visible marker:

```powershell
.\convert_images_to_editable_ppt.ps1 -Placeholder "文字"
```

## SVG exports

This workflow converts images from `resource/` into two SVG variants:

- `svg_output/embedded/*.embedded.svg`: exact visual SVG wrappers with the original raster image embedded.
- `svg_output/traced/*.traced.svg`: editable vector approximations made from quantized filled paths.
- `svg_output/preview_png/*.traced.png`: optional rendered previews for quick checking.

Run the default workflow:

```powershell
.\convert_images_to_svg.ps1
```

Generate previews too:

```powershell
.\convert_images_to_svg.ps1 -Preview
```

The default is tuned for AI-generated infographics and small labels:

```powershell
.\convert_images_to_svg.ps1 -Colors 64 -MaxSize 1400 -MinArea 1 -Preview
```

Smaller, cleaner SVGs:

```powershell
.\convert_images_to_svg.ps1 -Colors 20 -MaxSize 800 -MinArea 8 -Preview
```

Even more detail, with larger SVG files:

```powershell
.\convert_images_to_svg.ps1 -Colors 96 -MaxSize 1800 -MinArea 1 -MaxPathsPerColor 8000 -Preview
```

Notes:

- The traced SVG is an approximation. Text inside AI-generated images becomes vector shapes, not editable text.
- The embedded SVG is visually exact, but it still contains the raster image.
- For PowerPoint text repair, prefer `convert_images_to_editable_ppt.ps1` over traced SVG.
- The script uses ImageMagick for decoding, so an image can still work even when its extension is wrong.
- On this machine the wrapper prefers `D:\conda\miniconda3\python.exe` and auto-detects ImageMagick.
