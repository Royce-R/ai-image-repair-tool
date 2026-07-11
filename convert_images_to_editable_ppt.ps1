param(
    [string]$InputDir = ".\resource",
    [string]$OutputDir = ".\ppt_editable_output",
    [ValidateSet("dual", "mimic", "guide")]
    [string]$TemplateMode = "dual",
    [string]$Placeholder = "__AUTO__",
    [int]$DarkThreshold = 132,
    [int]$ColoredThreshold = 168,
    [int]$LineGap = 6,
    [int]$VerticalGap = 1,
    [int]$LineSuppressionLength = 0,
    [int]$MaxBoxes = 260,
    [string]$GuideColor = "#2563eb",
    [double]$GuideWidth = 0.0,
    [string]$FontFace = "Microsoft YaHei",
    [switch]$NoSampledStyle,
    [switch]$ReferenceSlides,
    [switch]$DebugPreview,
    [ValidateSet("auto", "off", "tesseract")]
    [string]$OcrMode = "auto",
    [ValidateSet("box", "image", "both")]
    [string]$OcrStrategy = "box",
    [string]$Tesseract = "",
    [string]$OcrLang = "chi_sim+eng",
    [int]$OcrPsm = 6,
    [string]$OcrBoxPsm = "13,7",
    [int]$OcrScale = 3,
    [double]$OcrMinConfidence = 45.0,
    [int]$OcrMaxBoxes = 60,
    [string]$FallbackGlyph = ([char]0x25A1),
    [string]$Magick = ""
)

$ErrorActionPreference = "Stop"

function Resolve-Python {
    $candidates = @(
        "D:\conda\miniconda3\python.exe",
        "python"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }

        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }

    throw "Python was not found. Install Python with NumPy, or edit Resolve-Python in this script."
}

function Resolve-Node {
    $command = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Node.js was not found. It is required for PPTX generation."
    }
    return $command.Source
}

$python = Resolve-Python
$node = Resolve-Node
if ($null -eq $env:HOME -or $env:HOME -eq "") {
    $env:HOME = $env:USERPROFILE
}
$outputPath = Resolve-Path -Path (New-Item -ItemType Directory -Force -Path $OutputDir)
$regionsJson = Join-Path $outputPath "text_regions.json"
$debugDir = Join-Path $outputPath "debug"
$detector = Join-Path $PSScriptRoot "tools\detect_text_regions.py"
$builder = Join-Path $PSScriptRoot "tools\create_editable_text_pptx.mjs"
$layerNamer = Join-Path $PSScriptRoot "tools\name_pptx_layers.py"

if (!(Test-Path $builder)) {
    throw "PPTX builder script was not found: $builder"
}

$detectorArgs = @(
    $detector,
    "--input-dir", $InputDir,
    "--output-json", $regionsJson,
    "--dark-threshold", $DarkThreshold,
    "--colored-threshold", $ColoredThreshold,
    "--line-gap", $LineGap,
    "--vertical-gap", $VerticalGap,
    "--line-suppression-length", $LineSuppressionLength,
    "--max-boxes", $MaxBoxes,
    "--ocr-mode", $OcrMode,
    "--ocr-strategy", $OcrStrategy,
    "--ocr-lang", $OcrLang,
    "--ocr-psm", $OcrPsm,
    "--ocr-box-psm", $OcrBoxPsm,
    "--ocr-scale", $OcrScale,
    "--ocr-min-confidence", $OcrMinConfidence,
    "--ocr-max-boxes", $OcrMaxBoxes,
    "--fallback-glyph", $FallbackGlyph
)

if ($Tesseract -ne "") {
    $detectorArgs += @("--tesseract", $Tesseract)
}
if ($Magick -ne "") {
    $detectorArgs += @("--magick", $Magick)
}
if ($DebugPreview) {
    $detectorArgs += @("--debug-dir", $debugDir)
}

& $python @detectorArgs
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $node $builder `
    --regions $regionsJson `
    --output-dir $outputPath `
    --placeholder $Placeholder `
    --guide-color $GuideColor `
    --guide-width $GuideWidth `
    --font-face $FontFace `
    --template-mode $TemplateMode `
    --sampled-style $(if ($NoSampledStyle) { "false" } else { "true" }) `
    --reference-slides $(if ($ReferenceSlides) { "true" } else { "false" })
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $python $layerNamer `
    --regions $regionsJson `
    --output-dir $outputPath `
    --template-mode $TemplateMode `
    --reference-slides $(if ($ReferenceSlides) { "true" } else { "false" })
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
