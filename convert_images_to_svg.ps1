param(
    [string]$InputDir = ".\resource",
    [string]$OutputDir = ".\svg_output",
    [ValidateSet("both", "embedded", "trace")]
    [string]$Mode = "both",
    [int]$Colors = 64,
    [int]$MaxSize = 1400,
    [double]$MinArea = 1.0,
    [int]$MaxPathsPerColor = 4000,
    [switch]$Preview,
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

$python = Resolve-Python
$scriptPath = Join-Path $PSScriptRoot "tools\raster_to_svg.py"

$argsList = @(
    $scriptPath,
    "--input-dir", $InputDir,
    "--output-dir", $OutputDir,
    "--mode", $Mode,
    "--colors", $Colors,
    "--max-size", $MaxSize,
    "--min-area", $MinArea,
    "--max-paths-per-color", $MaxPathsPerColor
)

if ($Preview) {
    $argsList += "--preview"
}

if ($Magick -ne "") {
    $argsList += @("--magick", $Magick)
}

& $python @argsList
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
