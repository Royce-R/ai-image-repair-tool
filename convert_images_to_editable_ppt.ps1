param(
    [string]$InputDir = ".\resource",
    [string]$OutputDir = ".\ppt_editable_output",
    [string]$Placeholder = " ",
    [int]$DarkThreshold = 132,
    [int]$ColoredThreshold = 168,
    [int]$LineGap = 6,
    [int]$VerticalGap = 1,
    [int]$MaxBoxes = 260,
    [string]$GuideColor = "#2563eb",
    [double]$GuideWidth = 1.0,
    [string]$FontFace = "Microsoft YaHei",
    [string]$SkillDir = "C:\Users\25296\.codex\plugins\cache\openai-primary-runtime\presentations\26.630.12135\skills\presentations"
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
$detector = Join-Path $PSScriptRoot "tools\detect_text_regions.py"
$builderSource = Join-Path $PSScriptRoot "tools\create_editable_text_pptx.mjs"
$setupScript = Join-Path $SkillDir "container_tools\setup_artifact_tool_workspace.mjs"

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
    --max-boxes $MaxBoxes
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
    --font-face $FontFace
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
