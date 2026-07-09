param(
    [Alias("Input", "In", "InputDir")]
    [string]$Source = ".\resource",

    [Alias("Out", "OutputDir")]
    [string]$Output = ".\output",

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

    [string]$Magick = "",
    [string]$SkillDir = "",
    [switch]$Check
)

$ErrorActionPreference = "Stop"

$ImageExtensions = @(".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tif", ".tiff")
$MagickCandidates = @(
    "D:\ImageMagick-7.1.2-Q16-HDRI\magick.exe",
    "C:\Program Files\ImageMagick-7.1.2-Q16-HDRI\magick.exe",
    "C:\Program Files\ImageMagick-7.1.1-Q16-HDRI\magick.exe",
    "C:\Program Files\ImageMagick-7.1.0-Q16-HDRI\magick.exe"
)

function Get-InputImageFiles {
    param([string]$InputDir)

    return @(Get-ChildItem -LiteralPath $InputDir -File |
        Where-Object { $ImageExtensions -contains $_.Extension.ToLowerInvariant() } |
        Sort-Object Name)
}

function Get-ImageInputSummary {
    param([string]$Path)

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $item = Get-Item -LiteralPath $resolved.Path
    $supported = ($ImageExtensions -join ", ")

    if ($item.PSIsContainer) {
        $images = Get-InputImageFiles -InputDir $item.FullName
        if ($images.Count -eq 0) {
            throw "No supported image files found in input folder: $($item.FullName). Supported extensions: $supported"
        }
        return @{
            Kind = "Directory"
            Path = $item.FullName
            ImageCount = $images.Count
            Images = $images
        }
    }

    $extension = $item.Extension.ToLowerInvariant()
    if ($ImageExtensions -notcontains $extension) {
        throw "Input file is not a supported image: $($item.FullName). Supported extensions: $supported"
    }

    return @{
        Kind = "File"
        Path = $item.FullName
        ImageCount = 1
        Images = @($item)
    }
}

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

    throw "Python was not found. Install Python with NumPy."
}

function Resolve-Node {
    $command = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Node.js was not found. It is required for PPTX generation."
    }
    return $command.Source
}

function Resolve-Magick {
    param([string]$Requested)

    $candidates = @()
    if ($Requested -ne "") {
        $candidates += $Requested
    }
    $candidates += "magick"
    $candidates += $MagickCandidates

    foreach ($candidate in $candidates) {
        if ($candidate -eq "") {
            continue
        }
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }

    throw "ImageMagick 'magick' was not found. Install ImageMagick or pass -Magick."
}

function Resolve-Tesseract {
    param([string]$Requested)

    $candidates = @()
    if ($Requested -ne "") {
        $candidates += $Requested
    }
    $candidates += @(
        "tesseract",
        "D:\Tesseract-OCR\tesseract.exe",
        "C:\Program Files\Tesseract-OCR\tesseract.exe",
        "C:\Program Files (x86)\Tesseract-OCR\tesseract.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -eq "") {
            continue
        }
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }

    return $null
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

function Write-CheckLine {
    param(
        [ValidateSet("OK", "WARN", "FAIL")]
        [string]$Status,
        [string]$Name,
        [string]$Detail
    )

    $color = "Green"
    if ($Status -eq "WARN") {
        $color = "Yellow"
    }
    elseif ($Status -eq "FAIL") {
        $color = "Red"
    }

    Write-Host ("[{0}] {1}: {2}" -f $Status, $Name, $Detail) -ForegroundColor $color
}

function Invoke-PreflightCheck {
    $failures = 0
    $warnings = 0

    Write-Host "AI Image Repair Tool preflight"
    Write-Host "Target: $Target"

    try {
        $summary = Get-ImageInputSummary -Path $Source
        Write-CheckLine -Status "OK" -Name "Input" -Detail "$($summary.ImageCount) image(s) in $($summary.Path)"
    }
    catch {
        $failures += 1
        Write-CheckLine -Status "FAIL" -Name "Input" -Detail $_.Exception.Message
    }

    try {
        $python = Resolve-Python
        $version = (& $python -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw ($version -join "`n")
        }
        Write-CheckLine -Status "OK" -Name "Python" -Detail "$python ($version)"

        $numpyVersion = (& $python -c "import numpy; print(numpy.__version__)" 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "NumPy import failed: $($numpyVersion -join "`n")"
        }
        Write-CheckLine -Status "OK" -Name "NumPy" -Detail $numpyVersion
    }
    catch {
        $failures += 1
        Write-CheckLine -Status "FAIL" -Name "Python/NumPy" -Detail $_.Exception.Message
    }

    try {
        $magickPath = Resolve-Magick -Requested $Magick
        $magickVersion = (& $magickPath -version 2>&1 | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0) {
            throw ($magickVersion -join "`n")
        }
        Write-CheckLine -Status "OK" -Name "ImageMagick" -Detail "$magickPath ($magickVersion)"
    }
    catch {
        $failures += 1
        Write-CheckLine -Status "FAIL" -Name "ImageMagick" -Detail $_.Exception.Message
    }

    if ($Target -eq "ppt" -or $Target -eq "both") {
        try {
            $node = Resolve-Node
            $nodeVersion = (& $node --version 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw ($nodeVersion -join "`n")
            }
            Write-CheckLine -Status "OK" -Name "Node.js" -Detail "$node ($nodeVersion)"
        }
        catch {
            $failures += 1
            Write-CheckLine -Status "FAIL" -Name "Node.js" -Detail $_.Exception.Message
        }

        try {
            $resolvedSkillDir = Resolve-PresentationSkillDir -Requested $SkillDir
            Write-CheckLine -Status "OK" -Name "Presentation skill" -Detail $resolvedSkillDir
        }
        catch {
            $failures += 1
            Write-CheckLine -Status "FAIL" -Name "Presentation skill" -Detail $_.Exception.Message
        }

        if ($OcrMode -ne "off") {
            $tesseractPath = Resolve-Tesseract -Requested $Tesseract
            if ($null -eq $tesseractPath) {
                if ($OcrMode -eq "tesseract") {
                    $failures += 1
                    Write-CheckLine -Status "FAIL" -Name "Tesseract" -Detail "OCR mode is 'tesseract' but tesseract was not found."
                }
                else {
                    $warnings += 1
                    Write-CheckLine -Status "WARN" -Name "Tesseract" -Detail "Not found. The tool will use quiet placeholders unless you install Tesseract or pass -OcrMode off."
                }
            }
            else {
                $tesseractVersion = (& $tesseractPath --version 2>&1 | Select-Object -First 1)
                Write-CheckLine -Status "OK" -Name "Tesseract" -Detail "$tesseractPath ($tesseractVersion)"
            }
        }
        else {
            Write-CheckLine -Status "OK" -Name "Tesseract" -Detail "Skipped because -OcrMode off is set."
        }
    }

    try {
        $outputPath = Resolve-Path -Path (New-Item -ItemType Directory -Force -Path $Output)
        Write-CheckLine -Status "OK" -Name "Output" -Detail "Writable output root: $outputPath"
    }
    catch {
        $failures += 1
        Write-CheckLine -Status "FAIL" -Name "Output" -Detail $_.Exception.Message
    }

    if ($failures -gt 0) {
        Write-Host "Preflight failed with $failures failure(s) and $warnings warning(s)."
        return 1
    }

    Write-Host "Preflight passed with $warnings warning(s)."
    return 0
}

function Resolve-ImageInput {
    param([string]$Path)

    $summary = Get-ImageInputSummary -Path $Path
    if ($summary.Kind -eq "Directory") {
        return @{
            InputDir = $summary.Path
            TempDir = $null
            ImageCount = $summary.ImageCount
        }
    }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("image_repair_tool_input_" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    $sourceItem = $summary.Images[0]
    Copy-Item -LiteralPath $sourceItem.FullName -Destination (Join-Path $tempDir $sourceItem.Name) -Force
    return @{
        InputDir = $tempDir
        TempDir = $tempDir
        ImageCount = 1
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
        Magick = $Magick
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
    if ($Magick -ne "") {
        $params.Magick = $Magick
    }

    & $scriptPath @params
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

if ($Check) {
    exit (Invoke-PreflightCheck)
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
