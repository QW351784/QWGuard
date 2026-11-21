; QW 安全电脑管家 —— Inno Setup 安装脚本
; 用法：先跑 build_windows.ps1 生成 Release 目录，再用 Inno Setup 编译本文件
; 目标：单文件 setup.exe，卸载后不留安装目录、配置目录与注册表项

#define MyAppName "QW 安全电脑管家"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "QW"
#define MyAppExeName "QWGuard.exe"

[Setup]
AppId={{8E2C1A44-9F3B-4C71-8A55-2E6D7B4C1F90}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\QW 安全电脑管家
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputDir=..\dist
OutputBaseFilename=QWGuard-Setup-{#MyAppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
DisableProgramGroupPage=yes
CloseApplications=yes
RestartApplications=no

[Languages]
; Inno Setup 6 只自带英文语言文件，chs/cht 会直接编译中止；
; 要中文界面得把 ChineseSimplified.isl 放进仓库再引用
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "autostart";   Description: "开机自启动"; Flags: unchecked

[Files]
; 主程序与 DLL（含 toolkit_native.dll）
Source: "..\app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
; 自带运行库（放在 vendor 目录，存在才装）
Source: "..\vendor\vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall skipifdoesntexist
; 运行库补全用的两个工具，原样放进 runtime 目录，不拆包不改二进制
Source: "..\vendor\runtime\*"; DestDir: "{app}\runtime"; Flags: recursesubdirs createallsubdirs skipifdoesntexist

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; Flags: waituntilterminated skipifdoesntexist
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[Registry]
; 自启动（按需）
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "QWGuard"; ValueData: """{app}\{#MyAppExeName}"""; Tasks: autostart; Flags: uninsdeletevalue

[UninstallRun]
; 先关进程，避免文件占用导致卸载残留
Filename: "taskkill.exe"; Parameters: "/F /IM {#MyAppExeName}"; Flags: runhidden; RunOnceId: "KillApp"
Filename: "reg.exe"; Parameters: "delete ""HKCU\Software\Microsoft\Windows\CurrentVersion\Run"" /v QWGuard /f"; Flags: runhidden; RunOnceId: "DelRun"

[UninstallDelete]
; 安装目录、配置目录、缓存与日志全部清掉
Type: filesandordirs; Name: "{app}"
Type: filesandordirs; Name: "{userappdata}\QWGuard"
Type: filesandordirs; Name: "{localappdata}\QWGuard"
Type: filesandordirs; Name: "{userappdata}\..\Local\QWGuard"
Type: dirifempty;      Name: "{autopf}\QWGuard"
Type: files;           Name: "{userdesktop}\{#MyAppName}.lnk"
