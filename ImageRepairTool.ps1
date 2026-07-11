param(
    [Parameter(Position = 0)]
    [Alias("Input", "In", "InputDir")]
    [string]$Source = ".\resource",

    [Alias("Out", "OutputDir")]
    [string]$Output = "",

    [ValidateSet("simple", "debug", "full")]
    [string]$OutputProfile = "simple",

    [ValidateSet("ppt", "svg", "both")]
    [string]$Target = "ppt",

    [ValidateSet("dual", "mimic", "guide")]
    [string]$TemplateMode = "dual",

    [switch]$ReferenceSlides,
    [switch]$DebugPreview,
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
    [int]$LineSuppressionLength = 0,
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
    [int]$OcrMaxBoxes = 60,
    [string]$FallbackGlyph = ([char]0x25A1),

    [ValidateSet("both", "embedded", "trace")]
    [string]$SvgMode = "both",
    [switch]$SvgPreview,
    [int]$SvgColors = 64,
    [int]$SvgMaxSize = 1400,
    [double]$SvgMinArea = 1.0,
    [int]$SvgMaxPathsPerColor = 4000,

    [string]$Magick = "",
    [switch]$Open,
    [switch]$Help,
    [switch]$Check
)

$ErrorActionPreference = "Stop"
$script:EffectiveDebugPreview = $DebugPreview -or ($OutputProfile -in @("debug", "full"))

$ImageExtensions = @(".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tif", ".tiff")
$MagickCandidates = @(
    "D:\ImageMagick-7.1.2-Q16-HDRI\magick.exe",
    "C:\Program Files\ImageMagick-7.1.2-Q16-HDRI\magick.exe",
    "C:\Program Files\ImageMagick-7.1.1-Q16-HDRI\magick.exe",
    "C:\Program Files\ImageMagick-7.1.0-Q16-HDRI\magick.exe"
)

function Write-Usage {
    Write-Host @"
AI Image Repair Tool

Simple use:
  Drag an image or folder onto RepairImage.cmd
  .\ImageRepairTool.ps1 "image.png"
  .\ImageRepairTool.ps1 -Input "image.png"
  .\ImageRepairTool.ps1 -Input ".\resource" -Output ".\output"

Common modes:
  -Check                         Check dependencies only.
  -Open                          Open the output folder when finished.
  -OutputProfile simple          Write only final files and START_HERE.txt. Default.
  -OutputProfile debug           Keep debug previews and intermediate files.
  -OutputProfile full            Keep every generated artifact.
  -Target ppt|svg|both           Generate editable PPTX, SVG, or both.

Useful only when tuning:
  -OcrMode off                   Disable OCR and use placeholders.
  -OcrMode tesseract             Force OCR even on dense images.
  -OcrMaxBoxes 60                Auto-skip OCR on dense images above this count.
  -LineGap 10 -VerticalGap 2     Merge nearby characters more aggressively.
  -LineSuppressionLength 40      Separate text from long box/arrow/table lines.
  -DebugPreview                  Save detected text-box previews.
"@
}

if ($Help) {
    Write-Usage
    exit 0
}

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
            Push-Location $PSScriptRoot
            try {
                $packageCheck = (& $node -e "import('pptxgenjs').then(() => process.exit(0)).catch((error) => { console.error(error.message); process.exit(1); })" 2>&1)
            }
            finally {
                Pop-Location
            }
            if ($LASTEXITCODE -ne 0) {
                throw "pptxgenjs was not found. Run npm install before generating PPTX. $($packageCheck -join ' ')"
            }
            Write-CheckLine -Status "OK" -Name "PPTX package" -Detail "pptxgenjs is installed."
        }
        catch {
            $failures += 1
            Write-CheckLine -Status "FAIL" -Name "PPTX package" -Detail $_.Exception.Message
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
        $label = ConvertTo-SafePathName -Name (Split-Path -Leaf $summary.Path)
        return @{
            InputDir = $summary.Path
            TempDir = $null
            ImageCount = $summary.ImageCount
            Label = $label
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
        Label = (ConvertTo-SafePathName -Name $sourceItem.BaseName)
    }
}

function ConvertTo-SafePathName {
    param([string]$Name)

    $safe = [regex]::Replace([string]$Name, '[<>:"/\\|?*\x00-\x1f]', "_").Trim(" ._")
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "images"
    }
    if ($safe.Length -gt 60) {
        return $safe.Substring(0, 60)
    }
    return $safe
}

function New-DefaultOutputPath {
    param([hashtable]$InputInfo)

    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $label = ConvertTo-SafePathName -Name ([string]$InputInfo.Label)
    return Join-Path $PSScriptRoot ("results\{0}_{1}" -f $stamp, $label)
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
        LineSuppressionLength = $LineSuppressionLength
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
        OcrMaxBoxes = $OcrMaxBoxes
        FallbackGlyph = $FallbackGlyph
        Magick = $Magick
    }

    if ($ReferenceSlides) {
        $params.ReferenceSlides = $true
    }
    if ($script:EffectiveDebugPreview) {
        $params.DebugPreview = $true
    }
    if ($NoSampledStyle) {
        $params.NoSampledStyle = $true
    }

    $workflowOutput = New-Object System.Collections.Generic.List[string]
    & $scriptPath @params 2>&1 | ForEach-Object {
        $line = [string]$_
        $workflowOutput.Add($line) | Out-Null
        if ($OutputProfile -ne "simple" -or $line -match "^(OCR:|OCR |Processing |Warning:|ERROR:)" -or $line -match "text box\(es\)") {
            Write-Host $line
        }
    }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        if ($OutputProfile -eq "simple") {
            Write-Host "Detailed log:"
            $workflowOutput | ForEach-Object { Write-Host $_ }
        }
        exit $exitCode
    }
}

function Assert-ChildPath {
    param(
        [string]$Parent,
        [string]$Child
    )

    $parentPath = (Resolve-Path -LiteralPath $Parent).Path
    $childPath = (Resolve-Path -LiteralPath $Child).Path
    if ($childPath -eq $parentPath) {
        throw "Refusing to treat root path as child: $childPath"
    }
    if (-not $childPath.StartsWith($parentPath + [System.IO.Path]::DirectorySeparatorChar)) {
        throw "Path is outside expected output root: $childPath"
    }
}

function Copy-ResultFile {
    param(
        [string]$Source,
        [string]$Destination
    )

    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    return (Resolve-Path -LiteralPath $Destination).Path
}

function Publish-PptResults {
    param(
        [string]$PptOutput,
        [string]$OutputRoot,
        [hashtable]$InputInfo
    )

    $primaryFiles = @()
    $debugFiles = @()
    $combined = Join-Path $PptOutput "combined_editable_text_layer.pptx"
    $perImageDir = Join-Path $PptOutput "per_image"

    if ($OutputProfile -eq "simple") {
        if ($InputInfo.ImageCount -eq 1 -and (Test-Path $perImageDir)) {
            $single = @(Get-ChildItem -LiteralPath $perImageDir -Filter "*.pptx" -File | Sort-Object Name | Select-Object -First 1)
            if ($single.Count -gt 0) {
                $primaryFiles += Copy-ResultFile -Source $single[0].FullName -Destination (Join-Path $OutputRoot "editable_template.pptx")
            }
        }
        elseif (Test-Path $combined) {
            $primaryFiles += Copy-ResultFile -Source $combined -Destination (Join-Path $OutputRoot "combined_editable_text_layer.pptx")
            if (Test-Path $perImageDir) {
                $editableDir = Join-Path $OutputRoot "editable_pptx"
                New-Item -ItemType Directory -Force -Path $editableDir | Out-Null
                Get-ChildItem -LiteralPath $perImageDir -Filter "*.pptx" -File |
                    Sort-Object Name |
                    ForEach-Object {
                        $primaryFiles += Copy-ResultFile -Source $_.FullName -Destination (Join-Path $editableDir $_.Name)
                    }
            }
        }

        $debugDir = Join-Path $PptOutput "debug"
        if ($script:EffectiveDebugPreview -and (Test-Path $debugDir)) {
            $reviewDir = Join-Path $OutputRoot "review"
            New-Item -ItemType Directory -Force -Path $reviewDir | Out-Null
            Get-ChildItem -LiteralPath $debugDir -File |
                Sort-Object Name |
                ForEach-Object {
                    $debugFiles += Copy-ResultFile -Source $_.FullName -Destination (Join-Path $reviewDir $_.Name)
                }
        }

        Assert-ChildPath -Parent $OutputRoot -Child $PptOutput
        Remove-Item -LiteralPath $PptOutput -Recurse -Force
    }
    else {
        if (Test-Path $combined) {
            $primaryFiles += (Resolve-Path -LiteralPath $combined).Path
        }
        if (Test-Path $perImageDir) {
            $primaryFiles += @(Get-ChildItem -LiteralPath $perImageDir -Filter "*.pptx" -File | Sort-Object Name | ForEach-Object { $_.FullName })
        }
        $debugDir = Join-Path $PptOutput "debug"
        if (Test-Path $debugDir) {
            $debugFiles += @(Get-ChildItem -LiteralPath $debugDir -File | Sort-Object Name | ForEach-Object { $_.FullName })
        }
    }

    return @{
        PrimaryFiles = $primaryFiles
        DebugFiles = $debugFiles
    }
}

function Write-StartHere {
    param(
        [string]$OutputRoot,
        [array]$PrimaryFiles,
        [array]$DebugFiles,
        [array]$SvgPaths
    )

    $lines = @(
        "AI Image Repair Tool results",
        "",
        "Open these first:"
    )

    if ($PrimaryFiles.Count -eq 0 -and $SvgPaths.Count -eq 0) {
        $lines += "  No final files were recorded. Check the console output above."
    }
    foreach ($file in $PrimaryFiles) {
        $lines += "  $file"
    }
    foreach ($path in $SvgPaths) {
        $lines += "  $path"
    }

    if ($DebugFiles.Count -gt 0) {
        $lines += ""
        $lines += "Debug previews:"
        foreach ($file in $DebugFiles) {
            $lines += "  $file"
        }
    }

    $lines += ""
    $lines += "Profiles:"
    $lines += "  simple: final files only. Default."
    $lines += "  debug: keep detection previews and intermediate files."
    $lines += "  full: keep every generated artifact."
    $lines += ""
    $lines += "Run .\ImageRepairTool.ps1 -Help for examples."

    $startHere = Join-Path $OutputRoot "START_HERE.txt"
    Set-Content -LiteralPath $startHere -Value $lines -Encoding UTF8
    return (Resolve-Path -LiteralPath $startHere).Path
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

    $workflowOutput = New-Object System.Collections.Generic.List[string]
    & $scriptPath @params 2>&1 | ForEach-Object {
        $line = [string]$_
        $workflowOutput.Add($line) | Out-Null
        if ($OutputProfile -ne "simple" -or $line -match "^(Input:|Images:|== |embedded:|traced:|preview:|Warning:|ERROR:)") {
            Write-Host $line
        }
    }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        if ($OutputProfile -eq "simple") {
            Write-Host "Detailed log:"
            $workflowOutput | ForEach-Object { Write-Host $_ }
        }
        exit $exitCode
    }
}

if ($Check) {
    exit (Invoke-PreflightCheck)
}

$inputInfo = Resolve-ImageInput -Path $Source
if ([string]::IsNullOrWhiteSpace($Output)) {
    $Output = New-DefaultOutputPath -InputInfo $inputInfo
}
$outputPath = Resolve-Path -Path (New-Item -ItemType Directory -Force -Path $Output)
$primaryFiles = @()
$debugFiles = @()
$svgPaths = @()

try {
    if ($Target -eq "ppt" -or $Target -eq "both") {
        $pptOutput = Join-Path $outputPath "ppt"
        New-Item -ItemType Directory -Force -Path $pptOutput | Out-Null
        Write-Host "Creating editable PowerPoint output..."
        Invoke-PptWorkflow -InputDir $inputInfo.InputDir -OutputDir $pptOutput
        $pptResults = Publish-PptResults -PptOutput $pptOutput -OutputRoot $outputPath -InputInfo $inputInfo
        $primaryFiles += $pptResults.PrimaryFiles
        $debugFiles += $pptResults.DebugFiles
        Write-Host "PPT output ready."
    }

    if ($Target -eq "svg" -or $Target -eq "both") {
        $svgOutput = Join-Path $outputPath "svg"
        New-Item -ItemType Directory -Force -Path $svgOutput | Out-Null
        Write-Host "Creating SVG output..."
        Invoke-SvgWorkflow -InputDir $inputInfo.InputDir -OutputDir $svgOutput
        $svgPaths += (Resolve-Path -LiteralPath $svgOutput).Path
        Write-Host "SVG output: $svgOutput"
    }

    $startHere = Write-StartHere -OutputRoot $outputPath -PrimaryFiles $primaryFiles -DebugFiles $debugFiles -SvgPaths $svgPaths
    Write-Host "Start here: $startHere"
    foreach ($file in $primaryFiles) {
        Write-Host "Result: $file"
    }
    foreach ($path in $svgPaths) {
        Write-Host "Result: $path"
    }
    Write-Host "Done. Output root: $outputPath"
    if ($Open) {
        Start-Process -FilePath "explorer.exe" -ArgumentList "`"$outputPath`""
    }
}
finally {
    if ($null -ne $inputInfo.TempDir -and (Test-Path $inputInfo.TempDir)) {
        Remove-Item -LiteralPath $inputInfo.TempDir -Recurse -Force
    }
}
