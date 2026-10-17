$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This fixture exercises the Windows bootstrap.' }
$taskRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$taskOut = Join-Path $taskRepo 'out'
$taskFixture = Join-Path $taskOut ('bootstrap-pin-test-' + [guid]::NewGuid().ToString('N'))
$taskPriorGlobal = $env:GIT_CONFIG_GLOBAL
New-Item -ItemType Directory -Force -Path $taskFixture | Out-Null
$env:GIT_CONFIG_GLOBAL = Join-Path $taskFixture 'isolated.gitconfig'
function Invoke-FixtureGit {
    param([string]$Directory, [string[]]$Arguments)
    $taskOutput = & git.exe -C $Directory @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'Fixture Git command failed' }
    return ($taskOutput -join "`n").Trim()
}
function New-FixtureRepository {
    param([string]$Directory, [string]$FileName)
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    & git.exe -c init.defaultBranch=main init --quiet $Directory
    if ($LASTEXITCODE -ne 0) { throw 'Fixture Git initialization failed' }
    Set-Content -LiteralPath (Join-Path $Directory $FileName) -Value '# fixture'
    Invoke-FixtureGit $Directory @('add', $FileName) | Out-Null
    Invoke-FixtureGit $Directory @('-c','user.name=Bootstrap fixture','-c','user.email=fixture@local.invalid','commit','--quiet','-m','fixture') | Out-Null
    return Invoke-FixtureGit $Directory @('rev-parse','HEAD')
}
try {
    $taskDriver = Join-Path $taskFixture 'driver'
    $taskScripts = Join-Path $taskDriver 'scripts'
    $taskConfig = Join-Path $taskDriver 'config'
    New-Item -ItemType Directory -Force -Path $taskScripts, $taskConfig | Out-Null
    foreach ($taskName in @('bootstrap.ps1','common.ps1')) {
        Copy-Item -LiteralPath (Join-Path $taskRepo ('scripts/' + $taskName)) -Destination $taskScripts
    }
    Set-Content -LiteralPath (Join-Path $taskConfig 'gclient.py') -Value 'solutions = []'
    $taskXLang = Join-Path $taskFixture 'xlang'
    $taskActual = New-FixtureRepository $taskXLang 'CMakeLists.txt'
    Add-Content -LiteralPath (Join-Path $taskXLang 'CMakeLists.txt') -Value '# next revision'
    Invoke-FixtureGit $taskXLang @('add','CMakeLists.txt') | Out-Null
    Invoke-FixtureGit $taskXLang @('-c','user.name=Bootstrap fixture','-c','user.email=fixture@local.invalid','commit','--quiet','-m','next revision') | Out-Null
    $taskDefault = Invoke-FixtureGit $taskXLang @('rev-parse','HEAD')
    Invoke-FixtureGit $taskXLang @('checkout','--quiet','--detach',$taskActual) | Out-Null
    $taskElectron = Join-Path $taskDriver '.chromium/src/electron'
    $taskElectronRef = New-FixtureRepository $taskElectron 'fixture.txt'
    Set-Content -LiteralPath (Join-Path $taskConfig 'electron.ref') -Value $taskElectronRef
    Set-Content -LiteralPath (Join-Path $taskConfig 'xlang.ref') -Value $taskDefault
    $taskBootstrap = Join-Path $taskScripts 'bootstrap.ps1'
    $taskRejected = $false
    try { & $taskBootstrap -XLangRoot $taskXLang -SkipSync -ConfigureGit }
    catch { $taskRejected = $_.Exception.Message -like '*but this build pins*' }
    if (-not $taskRejected) { throw 'The default pin mismatch was not rejected' }
    & $taskBootstrap -XLangRoot $taskXLang -XLangRevision $taskActual -SkipSync -ConfigureGit
    if ((Get-Content -LiteralPath (Join-Path $taskConfig 'xlang.ref') -Raw).Trim() -ne $taskDefault) { throw 'Explicit workspace input changed the standalone pin' }
    $taskRejected = $false
    try { & $taskBootstrap -XLangRoot $taskXLang -XLangRevision $taskDefault -SkipSync -ConfigureGit }
    catch { $taskRejected = $_.Exception.Message -like '*but this build pins*' }
    if (-not $taskRejected) { throw 'An explicit revision was allowed to bypass actual checkout verification' }
    $taskRejected = $false
    try { & $taskBootstrap -XLangRoot $taskXLang -XLangRevision main -SkipSync -ConfigureGit }
    catch { $taskRejected = $true }
    if (-not $taskRejected) { throw 'A mutable branch name was accepted instead of a full SHA' }
    Invoke-FixtureGit $taskXLang @('checkout','--quiet','--detach',$taskDefault) | Out-Null
    & $taskBootstrap -XLangRoot $taskXLang -SkipSync -ConfigureGit
    Write-Output 'bootstrap_xlang_revision_contract=PASS; explicit exact pin, mismatch rejection, immutable input, standalone default preserved; no native build or network sync'
}
finally {
    if ($null -eq $taskPriorGlobal) { Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue }
    else { $env:GIT_CONFIG_GLOBAL = $taskPriorGlobal }
    $taskResolved = [IO.Path]::GetFullPath($taskFixture)
    $taskAllowed = [IO.Path]::GetFullPath($taskOut).TrimEnd('\') + '\'
    if (-not $taskResolved.StartsWith($taskAllowed, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $taskResolved -Leaf) -notlike 'bootstrap-pin-test-*') { throw 'Refusing cleanup outside the owned fixture directory' }
    Remove-Item -LiteralPath $taskResolved -Recurse -Force
}
