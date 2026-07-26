[CmdletBinding()]
param(
    [string]$XLangRoot,
    [string]$DepotToolsRoot,
    [string]$VisualStudioRoot,
    [string]$ElectronRepository = 'https://github.com/xlang-foundation/electron.git',
    [switch]$ConfigureGit,
    [switch]$SkipSync,
    [switch]$AllowDirtyElectron,
    [switch]$AllowDirtyXLang
)

. (Join-Path $PSScriptRoot 'common.ps1')

if ($env:OS -ne 'Windows_NT') {
    throw 'The current bootstrap driver supports Windows x64.'
}

$workspace = Get-WorkspaceRoot
$chromiumWorkspace = Get-ChromiumWorkspace
$sourceRoot = Get-ChromiumSourceRoot
$electronRoot = Join-Path $sourceRoot 'electron'
$resolvedXLangRoot = Resolve-XLangRoot -RequestedRoot $XLangRoot
$electronRevision = Get-PinnedRevision -Name electron
$xlangRevision = Get-PinnedRevision -Name xlang
$lock = Enter-WorkspaceLock -Name workspace

try {
    Install-GClientConfiguration

    if ($ConfigureGit) {
        Invoke-CheckedCommand -FilePath 'git.exe' -Arguments @(
            'config', '--global', 'core.longpaths', 'true'
        ) -WorkingDirectory $workspace
    }
    else {
        $longPaths = @(& git.exe config --global --get core.longpaths 2>$null)
        if ($LASTEXITCODE -ne 0 -or ($longPaths -join '').Trim().ToLowerInvariant() -ne 'true') {
            throw 'Git core.longpaths is not enabled. Re-run with -ConfigureGit before syncing Chromium.'
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $electronRoot '.git'))) {
        New-Item -ItemType Directory -Force -Path $sourceRoot | Out-Null
        Invoke-CheckedCommand -FilePath 'git.exe' -Arguments @(
            'clone', '--no-checkout', $ElectronRepository, $electronRoot
        ) -WorkingDirectory $workspace
        Invoke-CheckedCommand -FilePath 'git.exe' -Arguments @(
            '-C', $electronRoot, 'fetch', '--no-tags', 'origin', $electronRevision
        ) -WorkingDirectory $workspace
        Invoke-CheckedCommand -FilePath 'git.exe' -Arguments @(
            '-C', $electronRoot, 'checkout', '--detach', $electronRevision
        ) -WorkingDirectory $workspace
    }

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

    if ($SkipSync) {
        Write-Host 'Pinned source checkouts are ready; gclient sync was skipped.'
        return
    }

    $resolvedDepotTools = Resolve-DepotToolsRoot -RequestedRoot $DepotToolsRoot
    $resolvedVisualStudio = Resolve-VisualStudioRoot -RequestedRoot $VisualStudioRoot
    Set-ChromiumBuildEnvironment `
        -DepotToolsRoot $resolvedDepotTools `
        -VisualStudioRoot $resolvedVisualStudio

    $gclient = Join-Path $resolvedDepotTools 'gclient.bat'
    Invoke-CheckedCommand -FilePath $gclient -Arguments @(
        'sync',
        '--force',
        '--with_branch_heads',
        '--with_tags',
        '--revision', "src/electron@$electronRevision"
    ) -WorkingDirectory $chromiumWorkspace

    Ensure-CheckoutAlias -Name chrome
    Ensure-CheckoutAlias -Name third_party

    Write-Host 'Chromium and Electron dependencies are synchronized.'
}
finally {
    if ($null -ne $lock) {
        $lock.Dispose()
    }
}
