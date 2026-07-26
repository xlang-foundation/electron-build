[CmdletBinding()]
param(
    [string]$XLangRoot,
    [string]$DepotToolsRoot,
    [string]$VisualStudioRoot,
    [switch]$AllowDirtyElectron,
    [switch]$AllowDirtyXLang
)

. (Join-Path $PSScriptRoot 'common.ps1')

if ($env:OS -ne 'Windows_NT') {
    throw 'The current build driver supports Windows x64. The bridge and packaging code remain cross-platform.'
}

$workspace = Get-WorkspaceRoot
$electronRoot = Join-Path (Get-ChromiumSourceRoot) 'electron'
$resolvedXLangRoot = Resolve-XLangRoot -RequestedRoot $XLangRoot
$electronRevision = Get-PinnedRevision -Name electron
$xlangRevision = Get-PinnedRevision -Name xlang
$resolvedDepotTools = Resolve-DepotToolsRoot -RequestedRoot $DepotToolsRoot
$resolvedVisualStudio = Resolve-VisualStudioRoot -RequestedRoot $VisualStudioRoot
$cmake = Resolve-CMake -VisualStudioRoot $resolvedVisualStudio
$ninja = Resolve-Ninja -VisualStudioRoot $resolvedVisualStudio
$python = Resolve-Python

Assert-RepositoryRevision `
    -Repository $electronRoot `
    -ExpectedRevision $electronRevision `
    -Label 'Electron' `
    -AllowDirty:$AllowDirtyElectron
Assert-RepositoryRevision `
    -Repository $resolvedXLangRoot `
    -ExpectedRevision $xlangRevision `
    -Label 'XLang' `
    -AllowDirty:$AllowDirtyXLang

Ensure-CheckoutAlias -Name electron
Ensure-CheckoutAlias -Name chrome -Optional
Ensure-CheckoutAlias -Name third_party -Optional

$longPaths = @(& git.exe config --global --get core.longpaths 2>$null)
if ($LASTEXITCODE -ne 0 -or ($longPaths -join '').Trim().ToLowerInvariant() -ne 'true') {
    Write-Warning 'Git core.longpaths is not enabled. Run bootstrap.ps1 -ConfigureGit before the first Chromium sync.'
}

$drive = New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($workspace))
$freeGiB = [Math]::Round($drive.AvailableFreeSpace / 1GB, 1)
if ($freeGiB -lt 200) {
    Write-Warning "Only $freeGiB GiB is free. A clean Chromium checkout and build can require more than 200 GiB."
}

Write-Host ''
Write-Host 'Electron XLang build preflight passed.'
Write-Host "  Workspace:       $workspace"
Write-Host "  Electron:        $electronRevision"
Write-Host "  XLang:           $xlangRevision"
Write-Host "  XLang root:      $resolvedXLangRoot"
Write-Host "  depot_tools:     $resolvedDepotTools"
Write-Host "  Visual Studio:   $resolvedVisualStudio"
Write-Host "  CMake:           $cmake"
Write-Host "  Ninja:           $ninja"
Write-Host "  Python:          $($python.FilePath)"
Write-Host "  Free disk:       $freeGiB GiB"
