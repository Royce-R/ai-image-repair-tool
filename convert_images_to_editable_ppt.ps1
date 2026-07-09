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
    [int]$MaxBoxes = 260,
    [string]$GuideColor = "#2563eb",
    [double]$GuideWidth = 0.0,
    [string]$FontFace = "Microsoft YaHei",
    [switch]$NoSampledStyle,
    [switch]$ReferenceSlides,
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
    [string]$FallbackGlyph = ([char]0x25A1),
    [string]$SkillDir = ""
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

function Test-PresentationSkillDir {
    param([string]$Path)

    if ($Path -eq "") {
        return $false
    }

    $setupScript = Join-Path $Path "container_tools\setup_artifact_tool_workspace.mjs"
    return Test-Path $setupScript
}

function Resolve-PresentationSkillDir {
    param([string]$Requested)

    if ($Requested -ne "") {
        $resolved = Resolve-Path -LiteralPath $Requested -ErrorAction Stop
        if (Test-PresentationSkillDir -Path $resolved.Path) {
            return $resolved.Path
        }
        throw "The specified SkillDir does not contain container_tools\setup_artifact_tool_workspace.mjs: $($resolved.Path)"
    }

    $searchRoots = @()
    if ($env:CODEX_HOME -ne $null -and $env:CODEX_HOME -ne "") {
        $searchRoots += Join-Path $env:CODEX_HOME "plugins\cache\openai-primary-runtime\presentations"
    }
    if ($env:USERPROFILE -ne $null -and $env:USERPROFILE -ne "") {
        $searchRoots += Join-Path $env:USERPROFILE ".codex\plugins\cache\openai-primary-runtime\presentations"
    }

    $candidates = @()
    foreach ($root in $searchRoots) {
        if (!(Test-Path $root)) {
            continue
        }
        $versionDirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue
        foreach ($versionDir in $versionDirs) {
            $candidate = Join-Path $versionDir.FullName "skills\presentations"
            if (Test-PresentationSkillDir -Path $candidate) {
                $candidates += Get-Item -LiteralPath $candidate
            }
        }
    }

    if ($candidates.Count -gt 0) {
        return ($candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    }

    throw "Codex presentations artifact tool was not found. Run inside a Codex environment with the presentations plugin, or pass -SkillDir explicitly."
}

$python = Resolve-Python
$node = Resolve-Node
if ($null -eq $env:HOME -or $env:HOME -eq "") {
    $env:HOME = $env:USERPROFILE
}
$outputPath = Resolve-Path -Path (New-Item -ItemType Directory -Force -Path $OutputDir)
$regionsJson = Join-Path $outputPath "text_regions.json"
$detector = Join-Path $PSScriptRoot "tools\detect_text_regions.py"
$builderSource = Join-Path $PSScriptRoot "tools\create_editable_text_pptx.mjs"
$layerNamer = Join-Path $PSScriptRoot "tools\name_pptx_layers.py"
$resolvedSkillDir = Resolve-PresentationSkillDir -Requested $SkillDir
$setupScript = Join-Path $resolvedSkillDir "container_tools\setup_artifact_tool_workspace.mjs"

if (!(Test-Path $setupScript)) {
    throw "Artifact-tool setup script was not found: $setupScript"
}

& $python $detector `
    --input-dir $InputDir `
    --output-json $regionsJson `
    --dark-threshold $DarkThreshold `
    --colored-threshold $ColoredThreshold `
    --line-gap $LineGap `
    --vertical-gap $VerticalGap `
    --max-boxes $MaxBoxes `
    --ocr-mode $OcrMode `
    --ocr-strategy $OcrStrategy `
    --tesseract $Tesseract `
    --ocr-lang $OcrLang `
    --ocr-psm $OcrPsm `
    --ocr-box-psm $OcrBoxPsm `
    --ocr-scale $OcrScale `
    --ocr-min-confidence $OcrMinConfidence `
    --fallback-glyph $FallbackGlyph
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$workspace = Join-Path ([System.IO.Path]::GetTempPath()) "260708pic_element_extract_ppt_artifact"
& $node $setupScript --workspace $workspace
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$builder = Join-Path $workspace "create_editable_text_pptx.mjs"
Copy-Item -Path $builderSource -Destination $builder -Force

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
