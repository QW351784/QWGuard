# QW 安全电脑管家 —— 打安装包
# 前置：已执行 build_windows.ps1，且已安装 Inno Setup 6（ISCC.exe）
# 用法：powershell -ExecutionPolicy Bypass -File .\build_installer.ps1

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$release = "$root\app\build\windows\x64\runner\Release"
$dist = "$root\dist"
$vendor = "$root\vendor"

if (-not (Test-Path "$release\system_toolbox.exe")) {
    throw "未找到 Release 产物，请先运行 build_windows.ps1"
}

# 确认 DLL 已就位
$dll = "$release\toolkit_native.dll"
if (-not (Test-Path $dll)) {
    Copy-Item "$root\native\target\release\toolkit_native.dll" $release -Force
}

# 自带运行库：把 VC++ 2015-2022 x64 放进 vendor（没有就跳过，安装脚本会自动忽略）
if (-not (Test-Path $vendor)) { New-Item -ItemType Directory -Path $vendor | Out-Null }
if (-not (Test-Path "$vendor\vc_redist.x64.exe")) {
    Write-Host "提示：vendor\vc_redist.x64.exe 不存在，安装包不会自带运行库。"
    Write-Host "      可从微软官网下载 VC_redist.x64.exe 放入 vendor 目录。"
}

New-Item -ItemType Directory -Path $dist -Force | Out-Null

# 找 ISCC
$iscc = @(
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $iscc) { throw "未安装 Inno Setup 6，请先安装：https://jrsoftware.org/isinfo.php" }

Write-Host "==> 编译安装包"
& $iscc "$root\installer\setup.iss"
if ($LASTEXITCODE -ne 0) { throw "ISCC 编译失败" }

Get-ChildItem $dist | Format-Table Name, Length
Write-Host "==> 完成，输出在 $dist"
