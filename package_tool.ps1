param(
    [string]$DistDir = ".\dist",
    [string]$PackageName = "ai-image-repair-tool"
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path $PSScriptRoot
$distPath = Resolve-Path -Path (New-Item -ItemType Directory -Force -Path $DistDir)
$packageDir = Join-Path $distPath $PackageName
$zipPath = Join-Path $distPath "$PackageName.zip"

if (Test-Path $packageDir) {
    Remove-Item -LiteralPath $packageDir -Recurse -Force
}
if (Test-Path $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

New-Item -ItemType Directory -Force -Path $packageDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $packageDir "tools") | Out-Null

$rootFiles = @(
    "ImageRepairTool.ps1",
    "convert_images_to_editable_ppt.ps1",
    "convert_images_to_svg.ps1",
    "SVG_WORKFLOW.md",
    "README.md",
    "LICENSE",
    "requirements.txt"
)

foreach ($file in $rootFiles) {
    $source = Join-Path $root $file
    if (Test-Path $source) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $packageDir $file) -Force
    }
}

Get-ChildItem -LiteralPath (Join-Path $root "tools") -File |
    Where-Object { $_.Extension -in @(".py", ".mjs") } |
    ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $packageDir "tools\$($_.Name)") -Force
    }

Compress-Archive -Path (Join-Path $packageDir "*") -DestinationPath $zipPath -Force
Write-Host "Package folder: $packageDir"
Write-Host "Package zip:    $zipPath"
