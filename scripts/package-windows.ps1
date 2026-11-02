#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$AppPath = 'build/windows/CodexResetBar.exe',
    [string]$OutputDirectory = 'dist',
    [string]$Version,
    [string]$InnoSetupCompiler,
    [switch]$InstallInnoSetup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Build the Windows installer on Windows with Inno Setup 6.5 or newer.'
}
$repoRoot = Split-Path $PSScriptRoot -Parent
function Get-RepoPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}
function Test-InnoVersion([string]$Path) {
    $versionInfo = (Get-Item -LiteralPath $Path).VersionInfo
    return ($versionInfo.ProductMajorPart -gt 6 -or ($versionInfo.ProductMajorPart -eq 6 -and $versionInfo.ProductMinorPart -ge 5))
}
function Find-InnoCompiler {
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command -and (Test-InnoVersion $command.Source)) { return $command.Source }
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, (Join-Path $env:LOCALAPPDATA 'Programs'))) {
        if (-not $base) { continue }
        foreach ($edition in @('Inno Setup 6', 'Inno Setup 7')) {
            $candidate = Join-Path $base "$edition\ISCC.exe"
            if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and (Test-InnoVersion $candidate)) { return $candidate }
        }
    }
    return $null
}

$appSource = Get-RepoPath $AppPath
$output = Get-RepoPath $OutputDirectory
if (-not $Version) {
    $project = [xml](Get-Content -LiteralPath (Join-Path $repoRoot 'windows/CodexResetBar/CodexResetBar.csproj') -Raw)
    $Version = [string]$project.Project.PropertyGroup.Version
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Version must have the form major.minor.patch.' }
foreach ($file in @($appSource, 'assets/app.ico', 'assets/app-icon.png', 'assets/wechat-qr.png', 'LICENSE', 'COMMERCIAL.md', 'windows/notices/LICENSE.NET.txt', 'windows/notices/LICENSE.WindowsForms.txt', 'windows/notices/THIRD-PARTY-NOTICES.NET.txt', 'installer/windows/ChineseSimplified.isl', 'installer/windows/LICENSE.InnoSetup.txt')) {
    if (-not (Test-Path -LiteralPath (Get-RepoPath $file) -PathType Leaf)) { throw "Missing installer input: $file" }
}
if (-not $InnoSetupCompiler) { $InnoSetupCompiler = Find-InnoCompiler }
if (-not $InnoSetupCompiler -and $InstallInnoSetup) {
    # Immutable official vendor EXE; SHA256 cross-checked against this manifest.
    # No package manager or downloaded PowerShell/shell script is required.
    # https://github.com/microsoft/winget-pkgs/tree/master/manifests/j/JRSoftware/InnoSetup/6.5.4
    $dependencyDirectory = Join-Path ([IO.Path]::GetTempPath()) ('CodexResetBar-InnoSetup-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dependencyDirectory | Out-Null
    try {
        $dependencyInstaller = Join-Path $dependencyDirectory 'innosetup-6.5.4.exe'
        Invoke-WebRequest -Uri 'https://github.com/jrsoftware/issrc/releases/download/is-6_5_4/innosetup-6.5.4.exe' -OutFile $dependencyInstaller -UseBasicParsing
        $dependencyHash = (Get-FileHash -LiteralPath $dependencyInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($dependencyHash -ne 'fa73bf47a4da250d185d07561c2bfda387e5e20db77e4570004cf6a133cc10b1') { throw 'Inno Setup dependency SHA256 mismatch.' }
        $dependencyProcess = Start-Process -FilePath $dependencyInstaller -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/CURRENTUSER' -Wait -PassThru
        if ($dependencyProcess.ExitCode -ne 0) { throw "Inno Setup dependency installation failed: $($dependencyProcess.ExitCode)" }
    }
    finally { Remove-Item -LiteralPath $dependencyDirectory -Recurse -Force -ErrorAction SilentlyContinue }
    $InnoSetupCompiler = Find-InnoCompiler
}
if (-not $InnoSetupCompiler) {
    throw 'Inno Setup 6.5+ is required. Use -InstallInnoSetup, or pass -InnoSetupCompiler to an existing ISCC.exe.'
}
$compiler = (Resolve-Path -LiteralPath $InnoSetupCompiler).Path
if (-not (Test-InnoVersion $compiler)) { throw 'Inno Setup 6.5 or newer is required.' }
New-Item -ItemType Directory -Path $output -Force | Out-Null
$setupName = "CodexResetBar-$Version-windows-x64-setup.exe"
$setupPath = Join-Path $output $setupName
# Remove only this version's prior output so a compiler failure cannot publish it.
Remove-Item -LiteralPath $setupPath, "$setupPath.sha256" -Force -ErrorAction SilentlyContinue
& $compiler "/DAppVersion=$Version" "/DRepoRoot=$repoRoot" "/DAppSource=$appSource" "/DOutputDirectory=$output" (Join-Path $repoRoot 'installer/windows/CodexResetBar.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed: $LASTEXITCODE" }
if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) { throw 'Inno Setup did not create the expected installer.' }
$hash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$setupPath.sha256", "$hash  $setupName`n", [Text.UTF8Encoding]::new($false))
Write-Output $setupPath
Write-Output "$setupPath.sha256"
