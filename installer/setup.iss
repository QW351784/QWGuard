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
Source: "..\app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs
; 自带运行库（放在 vendor 目录，存在才装）
Source: "..\vendor\vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall skipifsourcedoesntexist
; 运行库补全用的两个工具，原样放进 runtime 目录，不拆包不改二进制
Source: "..\vendor\runtime\*"; DestDir: "{app}\runtime"; Flags: recursesubdirs createallsubdirs skipifsourcedoesntexist

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

; ===================================================================
; 安装位置推荐：SSD(NVMe) 优先 → 避开系统盘 → 剩余容量最大
; 与 native/src/ext.rs 的 recommend_install_dir 同一套排序规则。
; Inno 是独立进程调不到 Rust 函数，这里用 Pascal 复刻：
;   · GetDriveType 枚举固定盘
;   · GetSpaceOnDisk64 取剩余空间
;   · 一次 PowerShell 批量取 MediaType/BusType（失败就当 HDD，有兜底）
; ===================================================================
[Code]
const
  QWFolder = 'QW 安全电脑管家';

function IsSystemDrive(D: Char): Boolean;
var
  Sys: String;
begin
  Sys := Uppercase(Copy(ExpandConstant('{sd}'), 1, 1));
  Result := (Uppercase(D) = Sys) or (Uppercase(D) = 'C');
end;

function FreeGB(D: Char): Int64;
var
  FreeBytes, TotalBytes: Int64;
begin
  Result := -1;
  if GetSpaceOnDisk64(D + ':\', FreeBytes, TotalBytes) then
    Result := FreeBytes div 1073741824;
end;

procedure LoadMediaMap(Map: TStringList);
var
  OutFile, Cmd, Line, D, M: String;
  RCode, I: Integer;
  Lines: TArrayOfString;
begin
  Map.Clear;
  OutFile := ExpandConstant('{tmp}\qw_media.txt');
  Cmd := '/c powershell -NoProfile -Command "Get-Volume | Where-Object {$_.DriveLetter} | ForEach-Object { $v=$_; try { $p=Get-Partition -DriveLetter $v.DriveLetter; $d=Get-PhysicalDisk -DeviceNumber $p.DiskNumber; Write-Output ($v.DriveLetter + ''='' + $d.MediaType + '','' + $d.BusType) } catch {} }" > "' + OutFile + '" 2>nul';
  Exec('cmd.exe', Cmd, '', SW_HIDE, ewWaitUntilTerminated, RCode);
  if LoadStringsFromFile(OutFile, Lines) then
    for I := 0 to GetArrayLength(Lines) - 1 do
    begin
      Line := Trim(Lines[I]);
      if (Length(Line) >= 2) and (Line[2] = '=') then
      begin
        D := Uppercase(Copy(Line, 1, 1));
        M := Uppercase(Copy(Line, 3, Length(Line)));
        Map.Values[D] := M;
      end;
    end;
  DeleteFile(OutFile);
end;

function BestDir(): String;
var
  Map: TStringList;
  D: Char;
  Media: String;
  Free, BestFree: Int64;
  Tier, BestTier: Integer;
  IsSys, BestIsSys, Found: Boolean;
  BestDrive: Char;
begin
  Map := TStringList.Create;
  try
    LoadMediaMap(Map);
    Found := False;
    BestDrive := 'C';
    BestTier := 99;
    BestFree := -1;
    BestIsSys := True;

    for D := 'C' to 'Z' do
    begin
      if GetDriveType(D + ':\') <> DRIVE_FIXED then
        Continue;
      Free := FreeGB(D);
      if Free < 0 then
        Continue;

      Media := Uppercase(Map.Values[D]);
      if Pos('NVME', Media) > 0 then
        Tier := 0
      else if Pos('SSD', Media) > 0 then
        Tier := 1
      else
        Tier := 2;

      IsSys := IsSystemDrive(D);

      if (not Found)
         or (Tier < BestTier)
         or ((Tier = BestTier) and BestIsSys and (not IsSys))
         or ((Tier = BestTier) and (BestIsSys = IsSys) and (Free > BestFree)) then
      begin
        BestDrive := D;
        BestTier := Tier;
        BestFree := Free;
        BestIsSys := IsSys;
        Found := True;
      end;
    end;

    if Found then
      Result := BestDrive + ':\' + QWFolder
    else
      Result := ExpandConstant('{autopf}\' + QWFolder);
  finally
    Map.Free;
  end;
end;

procedure InitializeWizard();
begin
  WizardForm.DirEdit.Text := BestDir();
end;
