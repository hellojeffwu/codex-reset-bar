#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SetupPath,
    [string]$ExpectedAppPath = 'build/windows/CodexResetBar.exe',
    [string]$ArtifactDirectory = 'build/windows-installer-test',
    [switch]$CaptureWizard
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Run this installer smoke test on Windows.' }
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not [IO.Path]::IsPathRooted($SetupPath)) { $SetupPath = Join-Path $repoRoot $SetupPath }
$setup = (Resolve-Path -LiteralPath $SetupPath).Path
if (-not [IO.Path]::IsPathRooted($ExpectedAppPath)) { $ExpectedAppPath = Join-Path $repoRoot $ExpectedAppPath }
$expectedApp = (Resolve-Path -LiteralPath $ExpectedAppPath).Path
if (-not [IO.Path]::IsPathRooted($ArtifactDirectory)) { $ArtifactDirectory = Join-Path $repoRoot $ArtifactDirectory }
$artifacts = [IO.Path]::GetFullPath($ArtifactDirectory)
New-Item -ItemType Directory -Path $artifacts -Force | Out-Null

$appId = '{A3E6E9B8-C853-46DC-BD21-D05C8AC87C6F}_is1'
$uninstallKeys = @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$appId", "HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$appId")
$checks = [Collections.Generic.List[object]]::new()
$testId = [Guid]::NewGuid().ToString('N')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "CodexResetBar-installer-$testId"
$installDirectory = Join-Path $testRoot 'Application with spaces'
$group = "CodexResetBar installer test $testId"
$startMenuDirectory = Join-Path ([Environment]::GetFolderPath('Programs')) $group
$desktopLink = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Codex 额度提醒.lnk'
$dataRoot = Join-Path $env:LOCALAPPDATA 'CodexResetBar'
$dataRootExisted = Test-Path -LiteralPath $dataRoot
$dataProbe = Join-Path $dataRoot "installer-test-$testId"
$startupKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startupBefore = Get-ItemPropertyValue -LiteralPath $startupKey -Name CodexResetBar -ErrorAction SilentlyContinue
$previousArtifactDirectory = $env:CODEX_SELF_TEST_ARTIFACT_DIR
$failure = $null
$ownsInstallation = $false
$dataProbeCreated = $false

function Assert-Check([bool]$Condition, [string]$Name) {
    $checks.Add([ordered]@{ check = $Name; passed = $Condition })
    if (-not $Condition) { throw "Installer check failed: $Name" }
}
function Invoke-CheckedProcess([string]$File, [string[]]$Arguments, [string]$Name, [int]$TimeoutSeconds = 120) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill()
        throw "$Name timed out."
    }
    Assert-Check ($process.ExitCode -eq 0) "$Name exit code"
}
function Get-TestUninstallEntry {
    foreach ($key in $uninstallKeys) {
        if (Test-Path -LiteralPath $key) { return Get-ItemProperty -LiteralPath $key }
    }
    return $null
}
function Assert-DataPreserved {
    foreach ($name in $dataHashes.Keys) {
        $path = Join-Path $dataProbe $name
        Assert-Check ((Test-Path -LiteralPath $path) -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $dataHashes[$name]) "Preserved dummy user data: $name"
    }
}
function Assert-NoMonitor {
    $running = @(Get-CimInstance Win32_Process -Filter "Name = 'CodexResetBar.exe'" | Where-Object { $_.ExecutablePath -eq (Join-Path $installDirectory 'CodexResetBar.exe') })
    Assert-Check ($running.Count -eq 0) 'Silent setup did not start the installed monitor'
}
function Capture-WelcomePage {
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class InstallerWindowCapture {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
}
'@
    $launcher = Start-Process -FilePath $setup -ArgumentList '/SP-', '/LANG=chinesesimplified' -PassThru
    $processIds = [Collections.Generic.HashSet[int]]::new()
    [void]$processIds.Add($launcher.Id)
    try {
        $window = $null
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while ($watch.Elapsed.TotalSeconds -lt 20 -and -not $window) {
            foreach ($process in @(Get-CimInstance Win32_Process)) {
                if ($processIds.Contains([int]$process.ParentProcessId)) { [void]$processIds.Add([int]$process.ProcessId) }
            }
            foreach ($processId in $processIds) {
                $candidate = Get-Process -Id $processId -ErrorAction SilentlyContinue
                if ($candidate -and $candidate.MainWindowHandle -ne [IntPtr]::Zero -and $candidate.MainWindowTitle -like '*Codex*') { $window = $candidate; break }
            }
            if (-not $window) { Start-Sleep -Milliseconds 200 }
        }
        if (-not $window) { throw 'No installer welcome window was available for capture.' }
        Start-Sleep -Milliseconds 600
        $window.Refresh()
        $rect = [InstallerWindowCapture+Rect]::new()
        if (-not [InstallerWindowCapture]::GetWindowRect($window.MainWindowHandle, [ref]$rect)) { throw 'Could not read installer window bounds.' }
        $bitmap = [Drawing.Bitmap]::new(($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $dc = $graphics.GetHdc()
        try { $captured = [InstallerWindowCapture]::PrintWindow($window.MainWindowHandle, $dc, 0) }
        finally { $graphics.ReleaseHdc($dc) }
        try {
            if (-not $captured) { throw 'Could not capture the installer welcome window.' }
            $bitmap.Save((Join-Path $artifacts 'installer-welcome.png'), [Drawing.Imaging.ImageFormat]::Png)
        }
        finally { $graphics.Dispose(); $bitmap.Dispose() }
        Assert-Check $true 'Captured welcome page without clicking or installing'
    }
    finally {
        # Only the just-created setup process tree is stopped, while still on Welcome.
        foreach ($processId in $processIds) { Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue }
    }
}

try {
    Assert-Check ($null -eq (Get-TestUninstallEntry)) 'No pre-existing installation for this AppId'
    Assert-Check (-not (Test-Path -LiteralPath $desktopLink)) 'No pre-existing application desktop shortcut'
    if ($CaptureWizard) { Capture-WelcomePage }
    New-Item -ItemType Directory -Path $testRoot, $dataProbe -Force | Out-Null
    $dataProbeCreated = $true
    Add-Type -AssemblyName System.Security
    $cipher = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes('installer_dummy_key_never_send'), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllText((Join-Path $dataProbe 'state.json'), (@{ protectedBarkKey = [Convert]::ToBase64String($cipher); sound = $false; popup = $false; phoneEnabled = $false } | ConvertTo-Json))
    [IO.File]::WriteAllText((Join-Path $dataProbe 'preferences.json'), '{"loginStartup":false,"testOnly":true}')
    $dataHashes = @{}
    foreach ($file in Get-ChildItem -LiteralPath $dataProbe -File) { $dataHashes[$file.Name] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }

    $baseArguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/SP-', '/NORESTART', '/NORESTARTAPPLICATIONS', '/LANG=chinesesimplified', "/DIR=`"$installDirectory`"", "/GROUP=`"$group`"")
    $ownsInstallation = $true
    Invoke-CheckedProcess $setup ($baseArguments + @('/TASKS=""', "/LOG=`"$(Join-Path $artifacts 'install.log')`"")) 'Silent install'
    Assert-NoMonitor
    Assert-Check (-not (Test-Path -LiteralPath $desktopLink)) 'Desktop shortcut is optional and initially unchecked'
    $installedExe = Join-Path $installDirectory 'CodexResetBar.exe'
    foreach ($file in @('CodexResetBar.exe', 'LICENSE', 'COMMERCIAL.md', 'README.md', 'Windows使用说明.md', 'assets/app.ico', 'assets/app-icon.png', 'assets/wechat-qr.png', 'notices/LICENSE.NET.txt', 'notices/LICENSE.WindowsForms.txt', 'notices/THIRD-PARTY-NOTICES.NET.txt', 'notices/LICENSE.InnoSetup.txt')) {
        Assert-Check (Test-Path -LiteralPath (Join-Path $installDirectory $file) -PathType Leaf) "Installed payload: $file"
    }
    Assert-Check ((Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $expectedApp -Algorithm SHA256).Hash) 'Installed EXE matches the published input'
    foreach ($file in @('LICENSE', 'COMMERCIAL.md', 'assets/app.ico', 'assets/app-icon.png', 'assets/wechat-qr.png')) {
        Assert-Check ((Get-FileHash -LiteralPath (Join-Path $installDirectory $file) -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath (Join-Path $repoRoot $file) -Algorithm SHA256).Hash) "Installed original asset matches source: $file"
    }
    $entry = Get-TestUninstallEntry
    Assert-Check ($null -ne $entry) 'Registered per-user uninstaller'
    Assert-Check ($entry.InstallLocation.TrimEnd('\') -eq $installDirectory) 'Uninstaller belongs to isolated install directory'
    $displayIconPath = ($entry.DisplayIcon -replace ',\s*0$', '').Trim('"')
    Assert-Check ($displayIconPath -eq (Join-Path $installDirectory 'assets/app.ico')) 'Uninstaller uses application icon'
    $shell = New-Object -ComObject WScript.Shell
    $startLink = Join-Path $startMenuDirectory 'Codex 额度提醒.lnk'
    Assert-Check (Test-Path -LiteralPath $startLink) 'Created start menu shortcut'
    Assert-Check ($shell.CreateShortcut($startLink).TargetPath -eq $installedExe) 'Start menu shortcut targets installed EXE'
    Assert-DataPreserved

    # Reinstall the same version as an upgrade check and explicitly opt into Desktop.
    Invoke-CheckedProcess $setup ($baseArguments + @('/TASKS="desktopicon"', "/LOG=`"$(Join-Path $artifacts 'upgrade.log')`"")) 'Silent upgrade'
    Assert-NoMonitor
    Assert-Check (Test-Path -LiteralPath $desktopLink) 'Optional desktop shortcut can be enabled'
    Assert-Check ($shell.CreateShortcut($desktopLink).TargetPath -eq $installedExe) 'Desktop shortcut targets installed EXE'
    Assert-DataPreserved

    # This isolated app entry point uses dummy DPAPI state and stub notifications.
    # Never launch the normal monitor, --probe, Codex CLI, or a real Bark request.
    $env:CODEX_SELF_TEST_ARTIFACT_DIR = Join-Path $artifacts 'installed-app-ui'
    $process = Start-Process -FilePath $installedExe -ArgumentList '--self-test' -PassThru -RedirectStandardOutput (Join-Path $artifacts 'self-test.log') -RedirectStandardError (Join-Path $artifacts 'self-test-error.log')
    if (-not $process.WaitForExit(90000)) { $process.Kill(); throw 'Installed EXE self-test timed out.' }
    Assert-Check ($process.ExitCode -eq 0) 'Installed EXE offline UI and DPAPI self-test'
    Assert-NoMonitor
    $startupAfter = Get-ItemPropertyValue -LiteralPath $startupKey -Name CodexResetBar -ErrorAction SilentlyContinue
    Assert-Check ($startupBefore -eq $startupAfter) 'Installer did not enable login startup'

    $uninstaller = Join-Path $installDirectory 'unins000.exe'
    Invoke-CheckedProcess $uninstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$(Join-Path $artifacts 'uninstall.log')`"") 'Silent uninstall'
    # The uninstaller's temporary helper finishes removing its original EXE asynchronously.
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ((Test-Path -LiteralPath $installDirectory) -and $watch.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 200 }
    Assert-Check (-not (Test-Path -LiteralPath $installDirectory)) 'Removed installed program directory'
    Assert-Check ($null -eq (Get-TestUninstallEntry)) 'Removed uninstaller registration'
    Assert-Check (-not (Test-Path -LiteralPath $startMenuDirectory)) 'Removed start menu shortcuts'
    Assert-Check (-not (Test-Path -LiteralPath $desktopLink)) 'Removed optional desktop shortcut'
    Assert-DataPreserved
    $startupAfter = Get-ItemPropertyValue -LiteralPath $startupKey -Name CodexResetBar -ErrorAction SilentlyContinue
    Assert-Check ($startupBefore -eq $startupAfter) 'Uninstaller preserved the existing login startup preference'
    $ownsInstallation = $false
}
catch { $failure = $_; $checks.Add([ordered]@{ check = $_.Exception.Message; passed = $false }) }
finally {
    $env:CODEX_SELF_TEST_ARTIFACT_DIR = $previousArtifactDirectory
    # On failure, clean up only an installation whose registry points at our temp path.
    if ($ownsInstallation) {
        $entry = Get-TestUninstallEntry
        $uninstaller = Join-Path $installDirectory 'unins000.exe'
        if ($entry -and $entry.InstallLocation.TrimEnd('\') -eq $installDirectory -and (Test-Path -LiteralPath $uninstaller)) {
            try { Invoke-CheckedProcess $uninstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') 'Failure cleanup uninstall' }
            catch { $checks.Add([ordered]@{ check = 'Failure cleanup uninstall'; passed = $false }) }
        }
    }
    $report = [ordered]@{
        passed = ($null -eq $failure)
        installer = [IO.Path]::GetFileName($setup)
        installerSha256 = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
        installDirectory = $installDirectory
        checks = @($checks.ToArray())
        limitation = 'Silent installation and offline self-test; no human click-through, real account, audio, or push acceptance is claimed.'
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $artifacts 'report.json') -Encoding UTF8
    # Delete only dummy data created by this test, after recording preservation checks.
    if ($dataProbeCreated) { Remove-Item -LiteralPath $dataProbe -Recurse -Force -ErrorAction SilentlyContinue }
    if ($dataProbeCreated -and -not $dataRootExisted -and (Test-Path -LiteralPath $dataRoot) -and @(Get-ChildItem -LiteralPath $dataRoot -Force).Count -eq 0) { Remove-Item -LiteralPath $dataRoot -Force }
    if ((Test-Path -LiteralPath $testRoot) -and @(Get-ChildItem -LiteralPath $testRoot -Force).Count -eq 0) { Remove-Item -LiteralPath $testRoot -Force }
}
if ($failure) { throw $failure }
Write-Output "PASS: installer install, upgrade, installed offline self-test, uninstall, and user data retention. Artifacts: $artifacts"
