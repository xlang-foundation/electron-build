[CmdletBinding()]
param(
    [string]$ArtifactDirectory,
    [string]$Archive,
    [string]$Version,
    [string]$VersionFile,
    [string]$TestModule,
    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 60
)

. (Join-Path $PSScriptRoot 'common.ps1')

if ($env:OS -ne 'Windows_NT') {
    throw 'The packaged-distribution verifier currently supports Windows x64.'
}
if ($Archive -and ($Version -or $VersionFile)) {
    throw '-Archive cannot be combined with -Version or -VersionFile.'
}
if ($Version -and $VersionFile) {
    throw '-Version and -VersionFile are mutually exclusive.'
}

$workspace = Get-WorkspaceRoot
$lock = Enter-WorkspaceLock -Name workspace

try {
    $python = Resolve-Python
    if ([string]::IsNullOrWhiteSpace($ArtifactDirectory)) {
        $ArtifactDirectory = Join-Path $workspace 'artifacts\win32-x64'
    }
    if ([string]::IsNullOrWhiteSpace($TestModule)) {
        $TestModule = Find-SingleBuildOutput `
            -Root (Join-Path $workspace 'out\bridge\win32-x64') `
            -Names @('xlang_bridge_event_test.dll') `
            -Label 'XLang bridge event test module'
    }

    $arguments = @($python.Prefix) + @(
        (Join-Path $workspace 'scripts\verify_package.py'),
        '--artifact-dir', $ArtifactDirectory,
        '--electron-ref', (Join-Path $workspace 'config\electron.ref'),
        '--xlang-ref', (Join-Path $workspace 'config\xlang.ref'),
        '--smoke-app', (Join-Path $workspace 'tests\xlang-smoke'),
        '--test-module', $TestModule,
        '--timeout-seconds', "$TimeoutSeconds"
    )
    if ($Archive) {
        $arguments += @('--archive', $Archive)
    }
    elseif ($Version) {
        $arguments += @('--version', $Version)
    }
    elseif ($VersionFile) {
        $arguments += @('--version-file', $VersionFile)
    }

    Invoke-CheckedCommand `
        -FilePath $python.FilePath `
        -Arguments $arguments `
        -WorkingDirectory $workspace
}
finally {
    if ($null -ne $lock) {
        $lock.Dispose()
    }
}
