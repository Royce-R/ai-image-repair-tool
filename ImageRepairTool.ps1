param(
    [Parameter(Mandatory = $true)]
    [Alias("Input", "In", "InputDir")]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [Alias("Out", "OutputDir")]
    [string]$Output,

    [ValidateSet("ppt", "svg", "both")]
    [string]$Target = "ppt",

    [ValidateSet("dual", "mimic", "guide")]
    [string]$TemplateMode = "dual",

    [switch]$ReferenceSlides,
    [string]$Placeholder = "__AUTO__",
    [switch]$AutoPlaceholder,
    [switch]$NoSampledStyle,
    [double]$GuideWidth = 0.0,
    [string]$GuideColor = "#2563eb",
    [string]$FontFace = "Microsoft YaHei",

    [int]$DarkThreshold = 132,
    [int]$ColoredThreshold = 168,
    [int]$LineGap = 6,
    [int]$VerticalGap = 1,
    [int]$MaxBoxes = 260,
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

    [ValidateSet("both", "embedded", "trace")]
    [string]$SvgMode = "both",
    [switch]$SvgPreview,
    [int]$SvgColors = 64,
    [int]$SvgMaxSize = 1400,
    [double]$SvgMinArea = 1.0,
    [int]$SvgMaxPathsPerColor = 4000,

    [string]$SkillDir = ""
)

$ErrorActionPreference = "Stop"

$ImageExtensions = @(".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tif", ".tiff")

function Resolve-ImageInput {
    param([string]$Path)

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $item = Get-Item -LiteralPath $resolved.Path
    if ($item.PSIsContainer) {
        return @{
            InputDir = $item.FullName
            TempDir = $null
        }
    }

    $extension = $item.Extension.ToLowerInvariant()
    if ($ImageExtensions -notcontains $extension) {
        throw "Input file is not a supported image: $($item.FullName)"
    }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("image_repair_tool_input_" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $tempDir $item.Name) -Force
    return @{
        InputDir = $tempDir
        TempDir = $tempDir
    }
}

function Invoke-PptWorkflow {
    param(
        [string]$InputDir,
        [string]$OutputDir
    )

    $scriptPath = Join-Path $PSScriptRoot "convert_images_to_editable_ppt.ps1"
    if (!(Test-Path $scriptPath)) {
        throw "PowerPoint workflow script was not found: $scriptPath"
    }

    $effectivePlaceholder = $Placeholder
    if ($AutoPlaceholder) {
        $effectivePlaceholder = "__AUTO__"
    }

    $effectiveGuideWidth = $GuideWidth
    if ($TemplateMode -eq "guide" -and $effectiveGuideWidth -le 0) {
        $effectiveGuideWidth = 1.0
    }

    $params = @{
        InputDir = $InputDir
        OutputDir = $OutputDir
        TemplateMode = $TemplateMode
        Placeholder = $effectivePlaceholder
        DarkThreshold = $DarkThreshold
        ColoredThreshold = $ColoredThreshold
        LineGap = $LineGap
        VerticalGap = $VerticalGap
        MaxBoxes = $MaxBoxes
        GuideColor = $GuideColor
        GuideWidth = $effectiveGuideWidth
        FontFace = $FontFace
        OcrMode = $OcrMode
        OcrStrategy = $OcrStrategy
        Tesseract = $Tesseract
        OcrLang = $OcrLang
        OcrPsm = $OcrPsm
        OcrBoxPsm = $OcrBoxPsm
        OcrScale = $OcrScale
        OcrMinConfidence = $OcrMinConfidence
        FallbackGlyph = $FallbackGlyph
    }

    if ($ReferenceSlides) {
        $params.ReferenceSlides = $true
    }
    if ($NoSampledStyle) {
        $params.NoSampledStyle = $true
    }
    if ($SkillDir -ne "") {
        $params.SkillDir = $SkillDir
    }

    & $scriptPath @params
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

function Invoke-SvgWorkflow {
    param(
        [string]$InputDir,
        [string]$OutputDir
    )

    $scriptPath = Join-Path $PSScriptRoot "convert_images_to_svg.ps1"
    if (!(Test-Path $scriptPath)) {
        throw "SVG workflow script was not found: $scriptPath"
    }

    $params = @{
        InputDir = $InputDir
        OutputDir = $OutputDir
        Mode = $SvgMode
        Colors = $SvgColors
        MaxSize = $SvgMaxSize
        MinArea = $SvgMinArea
        MaxPathsPerColor = $SvgMaxPathsPerColor
    }
    if ($SvgPreview) {
        $params.Preview = $true
    }

    & $scriptPath @params
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

$inputInfo = Resolve-ImageInput -Path $Source
$outputPath = Resolve-Path -Path (New-Item -ItemType Directory -Force -Path $Output)

try {
    if ($Target -eq "ppt" -or $Target -eq "both") {
        $pptOutput = Join-Path $outputPath "ppt"
        New-Item -ItemType Directory -Force -Path $pptOutput | Out-Null
        Write-Host "Creating editable PowerPoint output..."
        Invoke-PptWorkflow -InputDir $inputInfo.InputDir -OutputDir $pptOutput
        Write-Host "PPT output: $pptOutput"
    }

    if ($Target -eq "svg" -or $Target -eq "both") {
        $svgOutput = Join-Path $outputPath "svg"
        New-Item -ItemType Directory -Force -Path $svgOutput | Out-Null
        Write-Host "Creating SVG output..."
        Invoke-SvgWorkflow -InputDir $inputInfo.InputDir -OutputDir $svgOutput
        Write-Host "SVG output: $svgOutput"
    }

    Write-Host "Done. Output root: $outputPath"
}
finally {
    if ($null -ne $inputInfo.TempDir -and (Test-Path $inputInfo.TempDir)) {
        Remove-Item -LiteralPath $inputInfo.TempDir -Recurse -Force
    }
}
