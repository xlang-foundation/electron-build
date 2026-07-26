[CmdletBinding()]
param(
    [string]$XLangRoot,
    [ValidateSet('XLangRelease')]
    [string]$Configuration = 'XLangRelease',
    [switch]$SkipElectron
)

. (Join-Path $PSScriptRoot 'common.ps1')

if ($env:OS -ne 'Windows_NT') {
    throw 'The current test driver supports Windows x64.'
}

$workspace = Get-WorkspaceRoot
$sourceRoot = Get-ChromiumSourceRoot
$xlangBuild = Join-Path $workspace 'out\xlang\win32-x64'
$bridgeBuild = Join-Path $workspace 'out\bridge\win32-x64'
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

    $xlangEngine = Find-SingleBuildOutput `
        -Root $xlangBuild `
        -Names @('xlang_eng.dll') `
        -Label 'XLang engine'
    $xlangYaml = Find-SingleBuildOutput `
        -Root $xlangBuild `
        -Names @('xlang_yaml.dll') `
        -Label 'XLang YAML test module'
    $bridge = Find-SingleBuildOutput `
        -Root $bridgeBuild `
        -Names @('electron_xlang_bridge.dll') `
        -Label 'Electron XLang bridge'
    $smoke = Find-SingleBuildOutput `
        -Root $bridgeBuild `
        -Names @('electron_xlang_bridge_smoke.exe') `
        -Label 'native bridge smoke executable'
    $eventModule = Find-SingleBuildOutput `
        -Root $bridgeBuild `
        -Names @('xlang_bridge_event_test.dll') `
        -Label 'XLang bridge event test module'

    $smokeDirectory = Split-Path -Parent $smoke
    if ((Split-Path -Parent $bridge) -ne $smokeDirectory -or
        (Split-Path -Parent $eventModule) -ne $smokeDirectory) {
        throw 'The bridge, event test module, and native smoke executable must be built beside one another.'
    }
    if ((Split-Path -Parent $xlangEngine) -ne (Split-Path -Parent $xlangYaml)) {
        throw 'xlang_eng and xlang_yaml must be staged in the same runtime directory.'
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

    Write-Host 'All requested Electron XLang tests passed.'
}
finally {
    if ($null -ne $lock) {
        $lock.Dispose()
    }
}
