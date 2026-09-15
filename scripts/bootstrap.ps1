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

function Disable-UnneededUpdaterCipdPayloads {
    param([Parameter(Mandatory)][string]$DepsFile)

    if (-not (Test-Path -LiteralPath $DepsFile)) {
        return $false
    }

    # These signed Chrome/Chromium updater test binaries are not inputs to the
    # WebRTC SDK targets. Windows Defender may quarantine them, so disable only
    # their CIPD entries instead of weakening endpoint protection for the host.
    $updaterPayloads = @(
        'chrome_win_arm64',
        'chrome_win_arm64_sans_iid',
        'chrome_win_x86',
        'chrome_win_x86_64',
        'chrome_win_x86_64_sans_iid',
        'chrome_win_x86_sans_iid',
        'chromium_win_arm64',
        'chromium_win_arm64_sans_iid',
        'chromium_win_x86',
        'chromium_win_x86_64',
        'chromium_win_x86_64_sans_iid',
        'chromium_win_x86_sans_iid'
    )

    $content = [IO.File]::ReadAllText($DepsFile)
    $changed = 0
    foreach ($payload in $updaterPayloads) {
        $dependency = "src/third_party/updater/$payload/cipd"
        $escapedDependency = [regex]::Escape($dependency)
        $pattern = "(?ms)('$escapedDependency'\s*:\s*\{.*?'condition'\s*:\s*)'checkout_win'"
        $matches = [regex]::Matches($content, $pattern)
        if ($matches.Count -eq 1) {
            $content = [regex]::Replace($content, $pattern, '${1}''False''', 1)
            $changed++
            continue
        }

        $disabledPattern = "(?ms)('$escapedDependency'\s*:\s*\{.*?'condition'\s*:\s*)'False'"
        if ([regex]::Matches($content, $disabledPattern).Count -ne 1) {
            throw "Chromium DEPS has an unexpected updater payload definition: $dependency"
        }
    }

    if ($changed -gt 0) {
        [IO.File]::WriteAllText(
            $DepsFile,
            $content,
            [Text.UTF8Encoding]::new($false)
        )
        Write-Host "Disabled $changed unneeded Chrome/Chromium updater CIPD payloads."
    }

    # gclient rejects any modified file before dependency evaluation. Hide this
    # narrowly validated local DEPS override from its cleanliness check while
    # keeping the modified contents available to the DEPS evaluator.
    Invoke-CheckedCommand -FilePath 'git.exe' -Arguments @(
        '-C', (Split-Path -Parent $DepsFile),
        'update-index', '--skip-worktree', 'DEPS'
    ) -WorkingDirectory $workspace

    return $true
}

function Reset-CantorChromiumMetadataOverlays {
    param([Parameter(Mandatory)][string]$ChromiumSource)

    if (-not (Test-Path -LiteralPath (Join-Path $ChromiumSource '.git'))) {
        return
    }

    $overlayFiles = @(
        'DEPS',
        'third_party/webrtc_overrides/BUILD.gn'
    )
    Invoke-CheckedCommand -FilePath 'git.exe' -Arguments (@(
        '-C', $ChromiumSource, 'update-index', '--no-skip-worktree'
    ) + $overlayFiles) -WorkingDirectory $workspace
    Invoke-CheckedCommand -FilePath 'git.exe' -Arguments (@(
        '-C', $ChromiumSource, 'checkout', '--'
    ) + $overlayFiles) -WorkingDirectory $workspace
}

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
    # Cached runner builds apply two narrowly scoped metadata overlays after a
    # sync. Restore the tracked originals first so a changed Chromium pin can
    # update both files normally, then reapply the current overlays below.
    Reset-CantorChromiumMetadataOverlays -ChromiumSource $sourceRoot
    Install-GClientConfiguration

    if ($ConfigureGit) {
        Invoke-CheckedCommand -FilePath 'git.exe' -Arguments @(
            'config', '--global', 'core.longpaths', 'true'
        ) -WorkingDirectory $workspace

        $requiredSafeDirectories = @(
            $sourceRoot.Replace('\', '/'),
            $electronRoot.Replace('\', '/')
        )
        $safeDirectories = @(
            & git.exe config --global --get-all safe.directory 2>$null
        )
        foreach ($safeDirectory in $requiredSafeDirectories) {
            if ($safeDirectories -notcontains $safeDirectory) {
                Invoke-CheckedCommand -FilePath 'git.exe' -Arguments @(
                    'config', '--global', '--add',
                    'safe.directory', $safeDirectory
                ) -WorkingDirectory $workspace
            }
        }
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
    $syncArguments = @(
        'sync',
        # Every source is pinned by Electron's DEPS file. Avoid cloning the
        # complete multi-year history of Chromium and each nested dependency.
        # Do not pass --force: depot_tools otherwise resets an intentionally
        # narrow shallow-checkout refspec to every remote branch on each retry.
        '--no-history',
        '--revision', "src/electron@$electronRevision"
    )

    $chromiumDeps = Join-Path $sourceRoot 'DEPS'
    $depsReady = Disable-UnneededUpdaterCipdPayloads -DepsFile $chromiumDeps
    try {
        Invoke-CheckedCommand -FilePath $gclient -Arguments $syncArguments `
            -WorkingDirectory $chromiumWorkspace
    }
    catch {
        # On a new checkout Chromium's DEPS file is obtained by the first sync.
        # If that sync reached the updater payloads, patch the now-present DEPS
        # file and retry. Other failures are preserved unchanged.
        if ($depsReady -or -not (Disable-UnneededUpdaterCipdPayloads -DepsFile $chromiumDeps)) {
            throw
        }
        Write-Host 'Retrying dependency sync without the unneeded updater payloads.'
        Invoke-CheckedCommand -FilePath $gclient -Arguments $syncArguments `
            -WorkingDirectory $chromiumWorkspace
    }

    Ensure-CheckoutAlias -Name chrome
    Ensure-CheckoutAlias -Name third_party

    Write-Host 'Chromium and Electron dependencies are synchronized.'
}
finally {
    if ($null -ne $lock) {
        $lock.Dispose()
    }
}
