[CmdletBinding()]
param(
    [string]$XLangRoot,
    [string]$DepotToolsRoot,
    [string]$VisualStudioRoot,
    [ValidateSet('XLangRelease')]
    [string]$Configuration = 'XLangRelease',
    [ValidateRange(0, 512)]
    [int]$Jobs = 0,
    [switch]$SkipXLang,
    [switch]$SkipBridge,
    [switch]$SkipElectron,
    [switch]$SkipPackage,
    [switch]$SkipTests,
    [switch]$AllowDirtyElectron,
    [switch]$AllowDirtyXLang
)

. (Join-Path $PSScriptRoot 'common.ps1')

if ($env:OS -ne 'Windows_NT') {
    throw 'The current build driver supports Windows x64.'
}

$workspace = Get-WorkspaceRoot
$sourceRoot = Get-ChromiumSourceRoot
$electronRoot = Join-Path $sourceRoot 'electron'
$resolvedXLangRoot = Resolve-XLangRoot -RequestedRoot $XLangRoot
$electronRevision = Get-PinnedRevision -Name electron
$xlangRevision = Get-PinnedRevision -Name xlang
$shortElectronRevision = $electronRevision.Substring(0, 7)
$electronVersion = "0.0.0-xlang.$shortElectronRevision"
$platform = 'win32-x64'
$xlangBuild = Join-Path $workspace "out\xlang\$platform"
$bridgeBuild = Join-Path $workspace "out\bridge\$platform"
$runtimeDirectory = Join-Path $workspace "out\runtime\$platform"
$electronBuild = Join-Path $sourceRoot "out\$Configuration"
$artifactDirectory = Join-Path $workspace "artifacts\$platform"
$lock = Enter-WorkspaceLock -Name workspace
$runTests = -not $SkipTests

try {
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

    $resolvedDepotTools = Resolve-DepotToolsRoot -RequestedRoot $DepotToolsRoot
    $resolvedVisualStudio = Resolve-VisualStudioRoot -RequestedRoot $VisualStudioRoot
    $cmake = Resolve-CMake -VisualStudioRoot $resolvedVisualStudio
    $ninja = Resolve-Ninja -VisualStudioRoot $resolvedVisualStudio
    Set-ChromiumBuildEnvironment `
        -DepotToolsRoot $resolvedDepotTools `
        -VisualStudioRoot $resolvedVisualStudio
    Import-VisualStudioEnvironment -VisualStudioRoot $resolvedVisualStudio

    $parallelArguments = @('--parallel')
    if ($Jobs -gt 0) {
        $parallelArguments += "$Jobs"
    }

    if (-not $SkipXLang) {
        Invoke-CheckedCommand -FilePath $cmake -Arguments @(
            '-S', $resolvedXLangRoot,
            '-B', $xlangBuild,
            '-G', 'Ninja',
            "-DCMAKE_MAKE_PROGRAM=$ninja",
            '-DCMAKE_BUILD_TYPE=Release'
        ) -WorkingDirectory $workspace
        Invoke-CheckedCommand -FilePath $cmake -Arguments (
            @('--build', $xlangBuild, '--target', 'xlang_eng', 'xlang_yaml') +
            $parallelArguments
        ) -WorkingDirectory $workspace
    }

    $xlangEngine = Find-SingleBuildOutput `
        -Root $xlangBuild `
        -Names @('xlang_eng.dll') `
        -Label 'XLang engine'
    $xlangYaml = Find-SingleBuildOutput `
        -Root $xlangBuild `
        -Names @('xlang_yaml.dll') `
        -Label 'XLang YAML test module'

    if (-not $SkipBridge) {
        Invoke-CheckedCommand -FilePath $cmake -Arguments @(
            '-S', (Join-Path $electronRoot 'xlang_bridge'),
            '-B', $bridgeBuild,
            '-G', 'Ninja',
            "-DCMAKE_MAKE_PROGRAM=$ninja",
            '-DCMAKE_BUILD_TYPE=Release',
            '-DBUILD_TESTING=ON',
            "-DXLANG_ROOT=$resolvedXLangRoot"
        ) -WorkingDirectory $workspace
        Invoke-CheckedCommand -FilePath $cmake -Arguments (
            @(
                '--build', $bridgeBuild,
                '--target',
                'electron_xlang_bridge',
                'electron_xlang_bridge_smoke',
                'xlang_bridge_event_test'
            ) + $parallelArguments
        ) -WorkingDirectory $workspace
    }

    $bridge = Find-SingleBuildOutput `
        -Root $bridgeBuild `
        -Names @('electron_xlang_bridge.dll') `
        -Label 'Electron XLang bridge'
    $eventModule = Find-SingleBuildOutput `
        -Root $bridgeBuild `
        -Names @('xlang_bridge_event_test.dll') `
        -Label 'XLang bridge event test module'

    if (Test-Path -LiteralPath $runtimeDirectory -PathType Container) {
        $resolvedRuntime = [System.IO.Path]::GetFullPath($runtimeDirectory)
        $resolvedOut = [System.IO.Path]::GetFullPath((Join-Path $workspace 'out'))
        if (-not $resolvedRuntime.StartsWith($resolvedOut, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to replace runtime directory outside the workspace output: $resolvedRuntime"
        }
        Remove-Item -LiteralPath $runtimeDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $runtimeDirectory | Out-Null
    Copy-Item -LiteralPath $bridge -Destination $runtimeDirectory
    Copy-Item -LiteralPath $xlangEngine -Destination $runtimeDirectory
    Copy-Item -LiteralPath $xlangYaml -Destination $runtimeDirectory
    Copy-Item -LiteralPath $eventModule -Destination $runtimeDirectory

    if (-not $SkipElectron) {
        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'build') -PathType Container)) {
            throw 'Chromium dependencies are missing. Run scripts\bootstrap.ps1 before building Electron.'
        }

        $argsTemplate = Get-Content `
            -LiteralPath (Join-Path $workspace 'config\args.win-x64.gn') `
            -Raw
        $generatedArgs = $argsTemplate.TrimEnd() +
            "`n" +
            "override_electron_version = `"$electronVersion`"`n"
        Write-AtomicTextFile `
            -Path (Join-Path $electronBuild 'args.gn') `
            -Content $generatedArgs

        $gn = Join-Path $resolvedDepotTools 'gn.bat'
        $autoninja = Join-Path $resolvedDepotTools 'autoninja.bat'
        Invoke-CheckedCommand -FilePath $gn -Arguments @(
            'gen', "out\$Configuration"
        ) -WorkingDirectory $sourceRoot
        Invoke-CheckedCommand -FilePath $autoninja -Arguments @(
            '-C', "out\$Configuration", 'electron:electron_dist_zip'
        ) -WorkingDirectory $sourceRoot
    }

    if (-not $SkipPackage) {
        $distZip = Join-Path $electronBuild 'dist.zip'
        $versionFile = Join-Path $electronBuild 'version'
        if (-not (Test-Path -LiteralPath $distZip -PathType Leaf)) {
            throw "Electron dist.zip was not found: $distZip"
        }
        if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
            throw "Electron version output was not found: $versionFile"
        }

        $python = Resolve-Python
        $packageArguments = @($python.Prefix) + @(
            (Join-Path $workspace 'scripts\package.py'),
            '--dist-zip', $distZip,
            '--bridge', $bridge,
            '--engine', $xlangEngine,
            '--license', (Join-Path $resolvedXLangRoot 'LICENSE'),
            '--notice', (Join-Path $resolvedXLangRoot 'NOTICE'),
            '--electron-ref', (Join-Path $workspace 'config\electron.ref'),
            '--xlang-ref', (Join-Path $workspace 'config\xlang.ref'),
            '--version-file', $versionFile,
            '--output-dir', $artifactDirectory,
            '--platform', 'win32',
            '--arch', 'x64'
        )
        Invoke-CheckedCommand `
            -FilePath $python.FilePath `
            -Arguments $packageArguments `
            -WorkingDirectory $workspace
    }
}
finally {
    if ($null -ne $lock) {
        $lock.Dispose()
    }
}

if ($runTests) {
    $testArguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $PSScriptRoot 'test.ps1'),
        '-XLangRoot', $resolvedXLangRoot,
        '-Configuration', $Configuration
    )
    if ($SkipElectron) {
        $testArguments += '-SkipElectron'
    }
    & powershell.exe @testArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Test suite failed with exit code $LASTEXITCODE."
    }
}

Write-Host ''
Write-Host 'Electron XLang build completed.'
Write-Host "  Runtime staging: $runtimeDirectory"
if (-not $SkipPackage) {
    Write-Host "  Artifacts:       $artifactDirectory"
}
