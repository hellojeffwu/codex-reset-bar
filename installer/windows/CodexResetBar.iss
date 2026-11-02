; Compile through scripts/package-windows.ps1 with Inno Setup 6.5 or newer.
; AppId is stable across upgrades. User data is deliberately outside {app}.
#ifndef AppVersion
  #error AppVersion must be supplied by package-windows.ps1
#endif
#ifndef RepoRoot
  #error RepoRoot must be supplied by package-windows.ps1
#endif
#ifndef AppSource
  #error AppSource must be supplied by package-windows.ps1
#endif
#ifndef OutputDirectory
  #error OutputDirectory must be supplied by package-windows.ps1
#endif

[Setup]
AppId={{A3E6E9B8-C853-46DC-BD21-D05C8AC87C6F}
AppName=Codex 额度提醒
AppVersion={#AppVersion}
AppPublisher=hellojeffwu
AppPublisherURL=https://github.com/hellojeffwu/codex-reset-bar
AppSupportURL=https://github.com/hellojeffwu/codex-reset-bar/issues
AppContact=WeChat: wubenxincom
AppComments=个人非商业使用免费；商业使用须事先取得书面授权。
DefaultDirName={localappdata}\Programs\CodexResetBar
DefaultGroupName=Codex 额度提醒
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
WizardStyle=modern
DisableWelcomePage=no
DisableDirPage=no
DisableProgramGroupPage=no
LicenseFile={#RepoRoot}\LICENSE
InfoBeforeFile={#RepoRoot}\installer\windows\before-install.txt
SetupIconFile={#RepoRoot}\assets\app.ico
UninstallDisplayIcon={app}\assets\app.ico
UninstallDisplayName=Codex 额度提醒
OutputDir={#OutputDirectory}
OutputBaseFilename=CodexResetBar-{#AppVersion}-windows-x64-setup
VersionInfoVersion={#AppVersion}.0
VersionInfoProductVersion={#AppVersion}
Compression=lzma2
SolidCompression=yes
SetupMutex=CodexResetBarSetup
; Restart Manager receives only this installed file's full destination path.
; Do not add codex.exe, process-name taskkill commands, or the main app's mutex.
CloseApplications=yes
CloseApplicationsFilter=CodexResetBar.exe
RestartApplications=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "{#RepoRoot}\installer\windows\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#AppSource}"; DestDir: "{app}"; DestName: "CodexResetBar.exe"; Flags: ignoreversion
Source: "{#RepoRoot}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\COMMERCIAL.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\windows\README.md"; DestDir: "{app}"; DestName: "Windows使用说明.md"; Flags: ignoreversion
Source: "{#RepoRoot}\assets\app.ico"; DestDir: "{app}\assets"; Flags: ignoreversion
Source: "{#RepoRoot}\assets\app-icon.png"; DestDir: "{app}\assets"; Flags: ignoreversion
Source: "{#RepoRoot}\assets\wechat-qr.png"; DestDir: "{app}\assets"; Flags: ignoreversion
Source: "{#RepoRoot}\windows\notices\*.txt"; DestDir: "{app}\notices"; Flags: ignoreversion
Source: "{#RepoRoot}\installer\windows\LICENSE.InnoSetup.txt"; DestDir: "{app}\notices"; Flags: ignoreversion

[Icons]
Name: "{group}\Codex 额度提醒"; Filename: "{app}\CodexResetBar.exe"; WorkingDir: "{app}"; IconFilename: "{app}\assets\app.ico"
Name: "{group}\{cm:UninstallProgram,Codex 额度提醒}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\Codex 额度提醒"; Filename: "{app}\CodexResetBar.exe"; WorkingDir: "{app}"; IconFilename: "{app}\assets\app.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\CodexResetBar.exe"; Description: "{cm:LaunchProgram,Codex 额度提醒}"; Flags: nowait postinstall skipifsilent

; No Run-key entries or recursive deletion of user configuration are added.
; Inno Setup uninstalls only the files and shortcuts it installed.
