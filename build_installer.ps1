# QW 安全电脑管家 —— 打单文件安装包（Rust SFX）
# 前置：已执行 build_windows.ps1，且 Release 目录里已有 QWGuard.exe / toolkit_native.dll
# 用法：powershell -ExecutionPolicy Bypass -File .\build_installer.ps1
# 不再使用 Inno Setup 外壳：Inno 只解压再拉 Flutter 向导，进度条会卡在 0%。
# 这里直接把 Release 目录打成 payload.zip，追加到 qw_setup.exe 末尾。

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$release = "$root\app\build\windows\x64\runner\Release"
$dist = "$root\dist"
$native = "$root\native\target\release"

if (-not (Test-Path "$release\QWGuard.exe")) {
    throw "未找到 Release 产物，请先运行 build_windows.ps1"
}
if (-not (Test-Path "$native\qw_setup.exe")) {
    throw "未找到 native\target\release\qw_setup.exe，请先在 native 目录 cargo build --release --bin qw_setup"
}

# 补 DLL / qw_mcp
if (Test-Path "$native\toolkit_native.dll") {
    Copy-Item "$native\toolkit_native.dll" $release -Force
}
if (Test-Path "$native\qw_mcp.exe") {
    Copy-Item "$native\qw_mcp.exe" $release -Force
}
if (Test-Path "$root\app\assets") {
    Copy-Item "$root\app\assets" -Destination "$release\assets" -Recurse -Force
}
if (Test-Path "$root\vendor\runtime") {
    Copy-Item "$root\vendor\runtime" -Destination "$release\runtime" -Recurse -Force
}

# 重算清单
& "$root\build_manifest.ps1" -Dir $release

New-Item -ItemType Directory -Path $dist -Force | Out-Null
$payloadZip = Join-Path $dist "payload.zip"
if (Test-Path $payloadZip) { Remove-Item $payloadZip -Force }
Compress-Archive -Path "$release\*" -DestinationPath $payloadZip -CompressionLevel Optimal

$out = Join-Path $dist "QWGuard-Setup-1.1.0.exe"
Copy-Item "$native\qw_setup.exe" $out -Force
$payload = [IO.File]::ReadAllBytes($payloadZip)
$fs = [IO.File]::Open($out, 'Append', 'Write')
$off = [uint64]$fs.Length
$fs.Write($payload, 0, $payload.Length)
$tr = New-Object byte[] 24
[BitConverter]::GetBytes([uint64]$off).CopyTo($tr, 0)
[BitConverter]::GetBytes([uint64]$payload.Length).CopyTo($tr, 8)
[Text.Encoding]::ASCII.GetBytes('QWPAY1!!').CopyTo($tr, 16)
$fs.Write($tr, 0, 24)
$fs.Close()
Remove-Item $payloadZip -Force
Get-Item $out | Select-Object Name, Length
