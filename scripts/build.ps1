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
# Electron's Windows resource template uses the final prerelease identifier
# as the numeric fourth FILEVERSION component.
$electronVersion = "0.0.0-xlang.$shortElectronRevision.0"
$platform = 'win32-x64'
$xlangBuild = Join-Path $workspace "out\xlang\$platform"
$bridgeBuild = Join-Path $workspace "out\bridge\$platform"
$runtimeDirectory = Join-Path $workspace "out\runtime\$platform"
$electronBuild = Join-Path $sourceRoot "out\$Configuration"
$artifactDirectory = Join-Path $workspace "artifacts\$platform"
$packageStagingRoot = Join-Path $workspace "out\package-staging\$platform"
$packageStagingDirectory = $null
if (-not $SkipPackage) {
    $runIdentifier = "$PID-$([Guid]::NewGuid().ToString('N'))"
    $packageStagingDirectory = Join-Path $packageStagingRoot $runIdentifier
}
if ($SkipTests -and -not $SkipPackage) {
    throw '-SkipTests cannot be combined with packaging because only tested packages are published.'
}
if (-not $SkipPackage -and ($SkipXLang -or $SkipBridge -or $SkipElectron)) {
    throw (
        '-SkipXLang, -SkipBridge, and -SkipElectron require -SkipPackage ' +
        'because published artifacts must be rebuilt from the pinned sources.'
    )
}

function Remove-RunPackageStaging {
    if ($null -eq $packageStagingDirectory -or
        -not (Test-Path -LiteralPath $packageStagingDirectory -PathType Container)) {
        return
    }

    $resolvedStaging = [System.IO.Path]::GetFullPath($packageStagingDirectory)
    $resolvedStagingRoot = [System.IO.Path]::GetFullPath($packageStagingRoot)
    $stagingPrefix = $resolvedStagingRoot.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedStaging.StartsWith(
        $stagingPrefix,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Warning "Refusing to clean package staging outside $resolvedStagingRoot"
        return
    }

    try {
        Remove-Item -LiteralPath $resolvedStaging -Recurse -Force
    }
    catch {
        Write-Warning "Could not clean package staging $resolvedStaging`: $_"
    }
}

function Remove-AbandonedPackageStaging {
    if (-not (Test-Path -LiteralPath $packageStagingRoot -PathType Container)) {
        return
    }

    $resolvedStagingRoot = [System.IO.Path]::GetFullPath($packageStagingRoot)
    $candidates = @(
        Get-ChildItem -LiteralPath $resolvedStagingRoot -Directory -ErrorAction Stop
    )
    foreach ($candidate in $candidates) {
        if ($candidate.Name -notmatch '^(?<pid>[0-9]+)-[0-9a-fA-F]{32}$') {
            continue
        }
        $ownerProcessId = 0
        if (-not [int]::TryParse(
            $Matches['pid'],
            [ref]$ownerProcessId)) {
            continue
        }
        if ($null -ne (Get-Process -Id $ownerProcessId -ErrorAction SilentlyContinue)) {
            continue
        }
        if (($candidate.Attributes -band
            [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-Warning "Refusing to clean reparse-point staging $($candidate.FullName)"
            continue
        }

        $resolvedCandidate = [System.IO.Path]::GetFullPath(
            $candidate.FullName)
        $candidateParent = [System.IO.Path]::GetDirectoryName(
            $resolvedCandidate)
        if (-not $candidateParent.Equals(
            $resolvedStagingRoot,
            [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning "Refusing to clean package staging outside $resolvedStagingRoot"
            continue
        }
        if ($null -ne $packageStagingDirectory -and
            $resolvedCandidate.Equals(
                [System.IO.Path]::GetFullPath($packageStagingDirectory),
                [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        try {
            Remove-Item -LiteralPath $resolvedCandidate -Recurse -Force
        }
        catch {
            Write-Warning "Could not clean abandoned staging $resolvedCandidate`: $_"
        }
    }
}

$lock = Enter-WorkspaceLock -Name workspace
$runTests = -not $SkipTests
$savedElectronOutDir = [Environment]::GetEnvironmentVariable(
    'ELECTRON_OUT_DIR',
    'Process')
$env:ELECTRON_OUT_DIR = $Configuration

try {
    Remove-AbandonedPackageStaging
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
        $autoninjaArguments = @('-C', "out\$Configuration")
        if ($Jobs -gt 0) {
            $autoninjaArguments += @('-j', "$Jobs")
        }
        $autoninjaArguments += 'electron:electron_dist_zip'
        Invoke-CheckedCommand `
            -FilePath $autoninja `
            -Arguments $autoninjaArguments `
            -WorkingDirectory $sourceRoot
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
            '--output-dir', $packageStagingDirectory,
            '--platform', 'win32',
            '--arch', 'x64'
        )
        Invoke-CheckedCommand `
            -FilePath $python.FilePath `
            -Arguments $packageArguments `
            -WorkingDirectory $workspace
    }
}
catch {
    Remove-RunPackageStaging
    throw
}
finally {
    [Environment]::SetEnvironmentVariable(
        'ELECTRON_OUT_DIR',
        $savedElectronOutDir,
        'Process')
    if ($null -ne $lock) {
        $lock.Dispose()
    }
}

try {
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
        if (-not $SkipPackage) {
            $testArguments += @(
                '-VerifyPackage',
                '-PackageArtifactDirectory', $packageStagingDirectory,
                '-PublishPackage'
            )
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
}
finally {
    Remove-RunPackageStaging
}
