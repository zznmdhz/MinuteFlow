#ifndef MyAppVersion
  #error Define MyAppVersion from version.json
#endif
#ifndef SourceDir
  #error Define SourceDir for the self-contained published application
#endif

[Setup]
AppId={{26055E1F-70BE-4A6E-B701-E9E62978CFA7}
AppName=MinuteFlow
AppVersion={#MyAppVersion}
AppPublisher=MinuteFlow Contributors
AppPublisherURL=https://github.com/zznmdhz/MinuteFlow
DefaultDirName={localappdata}\Programs\MinuteFlow
DefaultGroupName=MinuteFlow
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#ArtifactDir}
OutputBaseFilename=MinuteFlow-v{#MyAppVersion}-Windows-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\MinuteFlow.exe
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut / 创建桌面快捷方式"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\MinuteFlow"; Filename: "{app}\MinuteFlow.exe"
Name: "{autodesktop}\MinuteFlow"; Filename: "{app}\MinuteFlow.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\MinuteFlow.exe"; Description: "Open MinuteFlow / 打开 MinuteFlow"; Flags: nowait postinstall skipifsilent

; User meetings and DPAPI credentials are outside {app}; uninstall preserves them.
