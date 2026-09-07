[CmdletBinding()]
param(
    [string]$XLangRoot,
    [ValidateSet('XLangRelease')]
    [string]$Configuration = 'XLangRelease',
    [switch]$SkipElectron,
    [switch]$VerifyPackage,
    [string]$PackageArtifactDirectory,
    [switch]$PublishPackage
)

. (Join-Path $PSScriptRoot 'common.ps1')

if ($env:OS -ne 'Windows_NT') {
    throw 'The current test driver supports Windows x64.'
}
if ($PublishPackage -and -not $VerifyPackage) {
    throw '-PublishPackage requires -VerifyPackage.'
}
if ($PackageArtifactDirectory -and -not $VerifyPackage) {
    throw '-PackageArtifactDirectory requires -VerifyPackage.'
}
if ($PublishPackage -and [string]::IsNullOrWhiteSpace($PackageArtifactDirectory)) {
    throw '-PublishPackage requires a staging -PackageArtifactDirectory.'
}

$workspace = Get-WorkspaceRoot
$sourceRoot = Get-ChromiumSourceRoot
$xlangBuild = Join-Path (Split-Path -Parent $workspace) 'out\build\x64-Release\bin'
$bridgeBuild = $xlangBuild
$electronBuild = Join-Path $sourceRoot "out\$Configuration"
$lock = Enter-WorkspaceLock -Name workspace

try {
    $python = Resolve-Python
    Invoke-CheckedCommand `
        -FilePath $python.FilePath `
        -Arguments (@($python.Prefix) + @(
            '-m', 'unittest', 'discover',
            '-s', (Join-Path $workspace 'tests\unit'),
            '-p', 'test_*.py'
        )) `
        -WorkingDirectory $workspace

    $xlangEngine = Join-Path $xlangBuild 'xlang3_runtime.dll'
    $xlangYaml = Join-Path $xlangBuild 'modules/xlang_yaml.x3pkg.dll'
    $bridge = Join-Path $bridgeBuild 'electron_xlang_bridge.dll'
    $smoke = Join-Path $bridgeBuild 'electron_xlang_bridge_smoke.exe'
    $eventModule = Join-Path $bridgeBuild 'xlang_bridge_event_test.dll'
    foreach ($artifact in @($bridge, $smoke, $eventModule)) {
        if (!(Test-Path -LiteralPath $artifact -PathType Leaf)) {
            throw "Required workspace Release artifact not found: $artifact"
        }
    }

    $smokeDirectory = Split-Path -Parent $smoke
    if ((Split-Path -Parent $bridge) -ne $smokeDirectory -or
        (Split-Path -Parent $eventModule) -ne $smokeDirectory) {
        throw 'The bridge, event test module, and native smoke executable must be built beside one another.'
    }
    if (!(Test-Path -LiteralPath $xlangEngine) -or !(Test-Path -LiteralPath $xlangYaml)) {
        throw 'Build the workspace Release XLang3 runtime and YAML module first.'
    }

    Invoke-CheckedCommand `
        -FilePath $smoke `
        -Arguments @((Split-Path -Parent $xlangEngine)) `
        -WorkingDirectory $smokeDirectory

    if (-not $SkipElectron) {
        $electron = Join-Path $electronBuild 'electron.exe'
        if (-not (Test-Path -LiteralPath $electron -PathType Leaf)) {
            throw "Built Electron executable was not found: $electron"
        }

        $savedRuntime = $env:XLANG_RUNTIME_DIR
        $savedBridge = $env:XLANG_BRIDGE_PATH
        $savedModule = $env:XLANG_TEST_MODULE
        try {
            $env:XLANG_RUNTIME_DIR = Split-Path -Parent $xlangEngine
            $env:XLANG_BRIDGE_PATH = $bridge
            $env:XLANG_TEST_MODULE = $eventModule
            Invoke-CheckedCommand `
                -FilePath $electron `
                -Arguments @((Join-Path $workspace 'tests\xlang-smoke')) `
                -WorkingDirectory $workspace
        }
        finally {
            $env:XLANG_RUNTIME_DIR = $savedRuntime
            $env:XLANG_BRIDGE_PATH = $savedBridge
            $env:XLANG_TEST_MODULE = $savedModule
        }
    }

    if ($VerifyPackage) {
        $versionFile = Join-Path $electronBuild 'version'
        if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
            throw "Electron version output was not found: $versionFile"
        }

        $verifyArtifactDirectory = $PackageArtifactDirectory
        if ([string]::IsNullOrWhiteSpace($verifyArtifactDirectory)) {
            $verifyArtifactDirectory = Join-Path $workspace 'artifacts\win32-x64'
        }
        if ($PublishPackage) {
            $resolvedStaging = [System.IO.Path]::GetFullPath(
                $verifyArtifactDirectory)
            $stagingRoot = [System.IO.Path]::GetFullPath(
                (Join-Path $workspace 'out\package-staging\win32-x64'))
            $stagingPrefix = $stagingRoot.TrimEnd(
                [System.IO.Path]::DirectorySeparatorChar,
                [System.IO.Path]::AltDirectorySeparatorChar
            ) + [System.IO.Path]::DirectorySeparatorChar
            if (-not $resolvedStaging.StartsWith(
                $stagingPrefix,
                [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to publish outside package staging: $resolvedStaging"
            }
        }

        $verifyArguments = @($python.Prefix) + @(
            (Join-Path $workspace 'scripts\verify_package.py'),
            '--artifact-dir', $verifyArtifactDirectory,
            '--version-file', $versionFile,
            '--electron-ref', (Join-Path $workspace 'config\electron.ref'),
            '--xlang-ref', (Join-Path $workspace 'config\xlang.ref'),
            '--smoke-app', (Join-Path $workspace 'tests\xlang-smoke'),
            '--test-module', $eventModule
        )
        if ($PublishPackage) {
            $verifyArguments += @(
                '--publish-dir',
                (Join-Path $workspace 'artifacts\win32-x64')
            )
        }
        Invoke-CheckedCommand `
            -FilePath $python.FilePath `
            -Arguments $verifyArguments `
            -WorkingDirectory $workspace
    }

    Write-Host 'All requested Electron XLang tests passed.'
}
finally {
    if ($null -ne $lock) {
        $lock.Dispose()
    }
}
