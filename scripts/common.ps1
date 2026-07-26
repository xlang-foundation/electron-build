Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WorkspaceRoot {
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Get-ChromiumWorkspace {
    return Join-Path (Get-WorkspaceRoot) '.chromium'
}

function Get-ChromiumSourceRoot {
    return Join-Path (Get-ChromiumWorkspace) 'src'
}

function Get-PinnedRevision {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('electron', 'xlang')]
        [string]$Name
    )

    $path = Join-Path (Get-WorkspaceRoot) "config\$Name.ref"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Pinned revision file is missing: $path"
    }

    $revision = (Get-Content -LiteralPath $path -Raw).Trim()
    if ($revision -notmatch '^[0-9a-fA-F]{40}$') {
        throw "Pinned revision in $path must be a full 40-character Git SHA."
    }

    return $revision.ToLowerInvariant()
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [string]$WorkingDirectory = (Get-Location).Path
    )

    if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        throw "Working directory does not exist: $WorkingDirectory"
    }

    Write-Host ">> $FilePath $($Arguments -join ' ')"
    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $FilePath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code $LASTEXITCODE`: $FilePath"
        }
    }
    finally {
        Pop-Location
    }
}

function Invoke-CapturedCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [string]$WorkingDirectory = (Get-Location).Path
    )

    Push-Location -LiteralPath $WorkingDirectory
    try {
        $output = @(& $FilePath @Arguments 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code $LASTEXITCODE`: $FilePath`n$($output -join [Environment]::NewLine)"
        }
        return ($output -join [Environment]::NewLine).Trim()
    }
    finally {
        Pop-Location
    }
}

function Get-RepositoryHead {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository
    )

    $resolved = (Resolve-Path -LiteralPath $Repository).Path
    $safePath = $resolved.Replace('\', '/')
    return Invoke-CapturedCommand -FilePath 'git.exe' -Arguments @(
        '-c', "safe.directory=$safePath",
        '-C', $resolved,
        'rev-parse', 'HEAD'
    )
}

function Assert-RepositoryRevision {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedRevision,

        [Parameter(Mandatory = $true)]
        [string]$Label,

        [switch]$AllowDirty
    )

    if (-not (Test-Path -LiteralPath (Join-Path $Repository '.git'))) {
        throw "$Label is not a Git checkout: $Repository"
    }

    $actual = Get-RepositoryHead -Repository $Repository
    if ($actual -ne $ExpectedRevision) {
        throw "$Label is at $actual, but this build pins $ExpectedRevision."
    }

    if (-not $AllowDirty) {
        $resolved = (Resolve-Path -LiteralPath $Repository).Path
        $safePath = $resolved.Replace('\', '/')
        $status = Invoke-CapturedCommand -FilePath 'git.exe' -Arguments @(
            '-c', "safe.directory=$safePath",
            '-C', $resolved,
            'status', '--porcelain'
        )
        if ($status) {
            throw "$Label has local changes. Commit, stash, or pass the explicit dirty-source override.`n$status"
        }
    }
}

function Resolve-XLangRoot {
    param([string]$RequestedRoot)

    if ([string]::IsNullOrWhiteSpace($RequestedRoot)) {
        $workspaceParent = Split-Path -Parent (Get-WorkspaceRoot)
        $RequestedRoot = Join-Path $workspaceParent 'xlang'
    }

    $fullPath = [System.IO.Path]::GetFullPath($RequestedRoot)
    if (-not (Test-Path -LiteralPath (Join-Path $fullPath 'CMakeLists.txt') -PathType Leaf)) {
        throw "XLang source was not found at $fullPath. Pass -XLangRoot explicitly."
    }

    return $fullPath
}

function Resolve-DepotToolsRoot {
    param([string]$RequestedRoot)

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        $candidates.Add($RequestedRoot)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:DEPOT_TOOLS)) {
        $candidates.Add($env:DEPOT_TOOLS)
    }

    $gclient = Get-Command 'gclient.bat' -ErrorAction SilentlyContinue
    if ($null -ne $gclient) {
        $candidates.Add((Split-Path -Parent $gclient.Source))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $candidates.Add((Join-Path $env:USERPROFILE 'depot_tools'))
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        $fullPath = [System.IO.Path]::GetFullPath($candidate)
        if ((Test-Path -LiteralPath (Join-Path $fullPath 'gclient.bat') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $fullPath 'autoninja.bat') -PathType Leaf)) {
            return $fullPath
        }
    }

    throw 'depot_tools was not found. Pass -DepotToolsRoot or set DEPOT_TOOLS.'
}

function Resolve-VisualStudioRoot {
    param([string]$RequestedRoot)

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        $candidates.Add($RequestedRoot)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:vs2022_install)) {
        $candidates.Add($env:vs2022_install)
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles})) {
        $candidates.Add((Join-Path ${env:ProgramFiles} 'Microsoft Visual Studio\2022\Community'))
        $candidates.Add((Join-Path ${env:ProgramFiles} 'Microsoft Visual Studio\2022\Professional'))
        $candidates.Add((Join-Path ${env:ProgramFiles} 'Microsoft Visual Studio\2022\Enterprise'))
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $detected = Invoke-CapturedCommand -FilePath $vswhere -Arguments @(
            '-latest',
            '-version', '[17.0,18.0)',
            '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
            '-property', 'installationPath'
        )
        if ($detected) {
            $candidates.Add($detected)
        }
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        $fullPath = [System.IO.Path]::GetFullPath($candidate)
        $vsDevCmd = Join-Path $fullPath 'Common7\Tools\VsDevCmd.bat'
        if (Test-Path -LiteralPath $vsDevCmd -PathType Leaf) {
            return $fullPath
        }
    }

    throw 'A Visual Studio 2022 installation with the C++ workload was not found.'
}

function Import-VisualStudioEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VisualStudioRoot
    )

    $vsDevCmd = Join-Path $VisualStudioRoot 'Common7\Tools\VsDevCmd.bat'
    $command = "`"$vsDevCmd`" -no_logo -arch=x64 -host_arch=x64 && set"
    $environmentLines = @(& $env:ComSpec /s /c $command)
    if ($LASTEXITCODE -ne 0) {
        throw "Visual Studio developer environment initialization failed with exit code $LASTEXITCODE."
    }

    foreach ($line in $environmentLines) {
        $separator = $line.IndexOf('=')
        if ($separator -le 0) {
            continue
        }
        $name = $line.Substring(0, $separator)
        $value = $line.Substring($separator + 1)
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }

    if ($null -eq (Get-Command 'cl.exe' -ErrorAction SilentlyContinue)) {
        throw 'Visual Studio environment loaded, but cl.exe is still unavailable.'
    }
}

function Resolve-CMake {
    param([string]$VisualStudioRoot)

    $command = Get-Command 'cmake.exe' -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    if (-not [string]::IsNullOrWhiteSpace($VisualStudioRoot)) {
        $candidate = Join-Path $VisualStudioRoot 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw 'cmake.exe was not found.'
}

function Resolve-Ninja {
    param([string]$VisualStudioRoot)

    if (-not [string]::IsNullOrWhiteSpace($VisualStudioRoot)) {
        $candidate = Join-Path $VisualStudioRoot 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $command = Get-Command 'ninja.exe' -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    throw 'ninja.exe was not found.'
}

function Resolve-Python {
    $python = Get-Command 'python.exe' -ErrorAction SilentlyContinue
    if ($null -ne $python) {
        return @{
            FilePath = $python.Source
            Prefix = @()
        }
    }

    $launcher = Get-Command 'py.exe' -ErrorAction SilentlyContinue
    if ($null -ne $launcher) {
        return @{
            FilePath = $launcher.Source
            Prefix = @('-3')
        }
    }

    throw 'Python 3 was not found.'
}

function Set-ChromiumBuildEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DepotToolsRoot,

        [Parameter(Mandatory = $true)]
        [string]$VisualStudioRoot
    )

    if (-not (($env:Path -split ';') -contains $DepotToolsRoot)) {
        $env:Path = "$DepotToolsRoot;$env:Path"
    }
    $env:DEPOT_TOOLS = $DepotToolsRoot
    $env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
    $env:ELECTRON_DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
    $env:ELECTRON_USE_THREE_WAY_MERGE_FOR_PATCHES = '1'
    $env:vs2022_install = $VisualStudioRoot

    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $windowsSdk = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
        if (Test-Path -LiteralPath $windowsSdk -PathType Container) {
            $env:WINDOWSSDKDIR = $windowsSdk
        }
    }
}

function Enter-WorkspaceLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $lockDirectory = Join-Path (Get-WorkspaceRoot) 'out\locks'
    New-Item -ItemType Directory -Force -Path $lockDirectory | Out-Null
    $lockPath = Join-Path $lockDirectory "$Name.lock"

    try {
        $stream = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None)
        $stream.SetLength(0)
        $payload = [System.Text.Encoding]::UTF8.GetBytes(
            "pid=$PID`nstarted=$([DateTimeOffset]::UtcNow.ToString('O'))`n")
        $stream.Write($payload, 0, $payload.Length)
        $stream.Flush()
        return $stream
    }
    catch {
        throw "Another '$Name' operation is already using this workspace ($lockPath)."
    }
}

function Find-SingleBuildOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string[]]$Names,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $matches = @()
    foreach ($name in $Names) {
        $matches += @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $name -ErrorAction SilentlyContinue)
    }
    $matches = @($matches | Sort-Object FullName -Unique)

    if ($matches.Count -eq 0) {
        throw "$Label was not found under $Root."
    }
    if ($matches.Count -gt 1) {
        throw "Multiple $Label files were found under ${Root}:`n$($matches.FullName -join [Environment]::NewLine)"
    }

    return $matches[0].FullName
}

function Write-AtomicTextFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporary = Join-Path $directory ".$([System.IO.Path]::GetFileName($Path)).$PID.tmp"
    try {
        [System.IO.File]::WriteAllText(
            $temporary,
            $Content,
            (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Install-GClientConfiguration {
    $workspace = Get-WorkspaceRoot
    $chromiumWorkspace = Get-ChromiumWorkspace
    $template = Join-Path $workspace 'config\gclient.py'
    if (-not (Test-Path -LiteralPath $template -PathType Leaf)) {
        throw "gclient configuration template is missing: $template"
    }

    New-Item -ItemType Directory -Force -Path $chromiumWorkspace | Out-Null
    Write-AtomicTextFile `
        -Path (Join-Path $chromiumWorkspace '.gclient') `
        -Content (Get-Content -LiteralPath $template -Raw)
}

function Ensure-CheckoutAlias {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('electron', 'chrome', 'third_party')]
        [string]$Name,

        [switch]$Optional
    )

    $workspace = Get-WorkspaceRoot
    $target = Join-Path (Get-ChromiumSourceRoot) $Name
    $alias = Join-Path $workspace $Name

    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        if ($Optional) {
            return
        }
        throw "Checkout directory is missing: $target"
    }

    if (Test-Path -LiteralPath $alias) {
        $item = Get-Item -Force -LiteralPath $alias
        $expected = [System.IO.Path]::GetFullPath($target).TrimEnd('\')
        $actualTargets = @($item.Target)
        foreach ($actualTarget in $actualTargets) {
            if (-not [string]::IsNullOrWhiteSpace($actualTarget) -and
                [System.IO.Path]::GetFullPath($actualTarget).TrimEnd('\') -eq $expected) {
                return
            }
        }
        throw "Workspace alias already exists but points elsewhere: $alias"
    }

    if ($env:OS -eq 'Windows_NT') {
        New-Item -ItemType Junction -Path $alias -Target $target | Out-Null
    }
    else {
        New-Item -ItemType SymbolicLink -Path $alias -Target $target | Out-Null
    }
}
