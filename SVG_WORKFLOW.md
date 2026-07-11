# Local Raster-to-SVG and Editable PowerPoint Workflow

## Tool entry point

Use `ImageRepairTool.ps1` when you want a simple input/output interface.
The input can be one image file or a folder of images.

For the simplest Windows workflow, drag an image or folder onto `RepairImage.cmd`.
If you double-click it without dragging anything, it processes `resource/`.

```powershell
.\ImageRepairTool.ps1 ".\resource\example.png"
.\ImageRepairTool.ps1 -Input .\resource -Output .\output
```

Common targets:

```powershell
.\ImageRepairTool.ps1 -Input .\resource -Output .\output
.\ImageRepairTool.ps1 -Input .\resource -Output .\output -Target svg -SvgMode embedded
.\ImageRepairTool.ps1 -Input .\resource -Output .\output -Target both -SvgMode embedded
```

If `-Output` is omitted, the tool writes to `results/<timestamp>_<input-name>/`.
The default `simple` output profile writes final files and `START_HERE.txt`.
Use `-OutputProfile debug` or `-OutputProfile full` to keep intermediate
PowerPoint working files under `output/ppt/`.

To create a distributable zip:

```powershell
.\package_tool.ps1
```

## Best option for PowerPoint repair

For manual PowerPoint editing, use the main entry point:

```powershell
.\ImageRepairTool.ps1 -Input .\resource
```

The main entry point creates reference slides by default: each image is followed
by an editable repair slide in the same PPTX, so you do not need to remember an
extra `-ReferenceSlides` option.

For low-level testing, use the editable PPTX workflow directly:

```powershell
.\convert_images_to_editable_ppt.ps1
```

It creates:

- `ppt_editable_output/combined_editable_text_layer.pptx`: one deck containing all images.
- `ppt_editable_output/per_image/*.editable_text_layer.pptx`: one exact-size PPTX per source image.
- `ppt_editable_output/text_regions.json`: detected text-line boxes.
- `ppt_editable_output/cleaned/*.text_removed.png`: raster base images with detected text removed.

Each slide uses the default `dual` mode:

- `01_original_reference_*`: the untouched source image, kept as the bottom reference layer.
- `02_cleaned_text_removed_*`: a full-slide cleaned image with detected text removed.
- `03_text_*`: PowerPoint-native editable text boxes over likely text lines.

In PowerPoint, open the Selection Pane. Hide `02_cleaned_text_removed` to see
the original wording underneath, then show it again to edit on the clean base.
The export also rewrites PPTX layer names so the Selection Pane should show:

- `01_original_reference`: original image.
- `02_cleaned_text_removed`: image with detected text covered.
- `03_text_001`, `03_text_002`, ...: editable text boxes, ordered from top to bottom.

The workflow now uses best-effort OCR by default. It tries to fill each editable
text box with recognized text. Unrecognized characters are replaced by `□`, so
the box keeps roughly the same visual footprint without filling the page with
repeated `字` placeholders.

Dense infographic-style images can contain many tiny labels, logos, and map
marks. In `auto` OCR mode, the tool skips OCR when one image has more than 60
detected text boxes, because that is usually faster and produces fewer bad text
overlays. When this happens in the default `dual` template mode, the generated
PowerPoint slide automatically keeps the original image visible and adds blue
editable-box guides instead of covering text with a cleaned white base. Use
`-OcrMode tesseract` to force OCR anyway.

### Low-level reference slides

The lower-level script keeps its original behavior. If you call it directly and
want paired reference/edit slides, pass:

```powershell
.\convert_images_to_editable_ppt.ps1 -ReferenceSlides
```

For each image this creates:

- Slide A: original-only reference slide, used to read the source wording.
- Slide B: editable slide with original image, cleaned base image, and editable text boxes.

This is usually the most practical setup even with OCR enabled: use OCR text as
a starting point, then compare against the reference slide and fix mistakes.

### Detection debug previews

To inspect the detected boxes before editing in PowerPoint:

```powershell
.\convert_images_to_editable_ppt.ps1 -ReferenceSlides -DebugPreview
```

This writes `debug/*.detected_boxes.svg` beside the PPT output. Red boxes are
editable text boxes, and blue dashed boxes show the cleaned mask regions.

### OCR controls

The default OCR strategy is per-box recognition. It is slower than whole-image
OCR, but usually works better for diagrams and PPT-like images:

```powershell
.\convert_images_to_editable_ppt.ps1 -OcrStrategy box
```

For faster, less precise OCR:

```powershell
.\convert_images_to_editable_ppt.ps1 -OcrStrategy image
```

To disable OCR and generate quiet placeholders only:

```powershell
.\convert_images_to_editable_ppt.ps1 -OcrMode off
```

To change the fallback character:

```powershell
.\convert_images_to_editable_ppt.ps1 -FallbackGlyph "＿"
```

### Alternative editing modes

To use the older blue-box locator mode without covering the original text:

```powershell
.\convert_images_to_editable_ppt.ps1 -TemplateMode guide -GuideWidth 1 -Placeholder " "
```

To use per-text-box background patches instead of a single cleaned base image:

```powershell
.\convert_images_to_editable_ppt.ps1 -TemplateMode mimic
```

If the detector misses text, try wider grouping:

```powershell
.\convert_images_to_editable_ppt.ps1 -LineGap 10 -VerticalGap 2
```

If labels are connected to boxes, arrows, or table rules, tune long-line
suppression:

```powershell
.\convert_images_to_editable_ppt.ps1 -LineSuppressionLength 40 -DebugPreview
```

If it creates too many boxes, make detection stricter:

```powershell
.\convert_images_to_editable_ppt.ps1 -DarkThreshold 115 -ColoredThreshold 150 -MaxBoxes 180
```

To force every editable box to use the same visible marker:

```powershell
.\convert_images_to_editable_ppt.ps1 -Placeholder "文字"
```

To use an auto-length placeholder that roughly fills each detected line:

```powershell
.\convert_images_to_editable_ppt.ps1 -Placeholder "__AUTO__"
```

This is useful for checking approximate font size and alignment, but it may cover
more of the original wording when you toggle the cleaned layer off.

To keep the current mode but show blue selection guides:

```powershell
.\convert_images_to_editable_ppt.ps1 -GuideWidth 1
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
