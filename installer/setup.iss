; QW 安全电脑管家 —— 安装包外壳（Inno Setup）
;
; 定位变了：Inno 不再负责“安装”，只负责两件事
;   1. 把 Flutter 编出来的整套程序释放到临时目录（单文件 exe 的容器作用）
;   2. 拉起 QWGuard-Setup.exe —— 那是 Rust + Flutter 写的安装向导本体
;
; 真正的安装动作（选目录 / 复制 / 快捷方式 / 注册表 / 运行库 / 卸载登记）
; 全部由 Rust 的 install_run 执行，界面的玻璃、粒子、页面切换都由 Flutter 渲染。
; 这样安装器和卸载器跟主程序是同一套技术栈，动画完全一致。

#define MyAppName "QW 安全电脑管家"
#define MyAppVersion "1.0.2"
#define MyAppPublisher "QW"
#define MyAppExeName "QWGuard.exe"
#define MySetupExeName "QWGuard-Setup.exe"

[Setup]
AppId={{8E2C1A44-9F3B-4C71-8A55-2E6D7B4C1F90}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
; 这个值只是给 Inno 内部占位用（它要有个目录概念），用户看不到，
; 因为下面 DisableDirPage=yes，路径选择在 Flutter 向导里做
DefaultDirName={autopf}\QWGuard
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
; 目录页 / 程序组页 / 任务页全部关掉：这些选项都在 Flutter 向导里
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
; 完成页也关掉：真正的「安装完成」界面是 Flutter 向导的最后一页，
; 外壳再弹一次「完成」会变成连续两个结束页
DisableFinishedPage=yes
CloseApplications=no
RestartApplications=no
; 外壳不写自己的卸载项，卸载项由 Rust 安装时登记（中文名、带图标）
Uninstallable=no

[Languages]
; 顺序即优先级：第一位是默认语言
;   1. 简体中文（默认）
;   2. 英文（第二语言）
;   3. 繁体中文（第三语言）
Name: "chinesesimplified";   MessagesFile: "ChineseSimplified.isl"
Name: "en";                  MessagesFile: "compiler:Default.isl"
Name: "chinesetraditional";   MessagesFile: "ChineseTraditional.isl"

[Files]
; 整套程序（含 QWGuard.exe / QWGuard-Setup.exe / QWGuard-Uninstall.exe / toolkit_native.dll）
; 释放到临时目录，装完由 Flutter 向导负责搬到最终位置。
; 不要加 deleteafterinstall：那个标志会在 [Files] 结束后就删文件，
; 而我们要在 ssPostInstall 阶段才去 Exec 它，加了就变成「文件已被删、拉不起来」。
; 临时目录由 Inno 自己在安装结束时清理。
Source: "..\app\build\windows\x64\runner\Release\*"; DestDir: "{tmp}\qwpayload"; Flags: recursesubdirs createallsubdirs

[Code]
// 时序要点：PrepareToInstall 跑在 [Files] 释放之前，那时 payload 还不存在，
// 在这里 Exec 一定失败。必须等 ssPostInstall —— 文件已经落地之后再拉起向导。
procedure CurStepChanged(CurStep: TSetupStep);
var
  RCode: Integer;
  SetupExe: String;
begin
  if CurStep = ssPostInstall then
  begin
    SetupExe := ExpandConstant('{tmp}\qwpayload\{#MySetupExeName}');
    if not FileExists(SetupExe) then
    begin
      MsgBox('安装包内部缺少安装向导文件，无法继续。请重新下载安装包。', mbError, MB_OK);
      Exit;
    end;
    if not Exec(SetupExe, '', ExpandConstant('{tmp}\qwpayload'), SW_SHOW, ewWaitUntilTerminated, RCode) then
      MsgBox('无法启动安装向导（QWGuard-Setup.exe 没能运行）。请确认杀毒软件没有拦截。', mbError, MB_OK)
    else if RCode <> 0 then
      MsgBox('安装向导未完成安装（退出码 ' + IntToStr(RCode) + '）。请重新运行安装包。', mbError, MB_OK);
  end;
end;
