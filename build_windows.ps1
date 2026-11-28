# 系统工具箱 —— Windows 一键构建脚本
# 用法：在项目根目录执行  powershell -ExecutionPolicy Bypass -File .\build_windows.ps1

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host "==> 项目根目录: $root"

# 1. 编译 Rust 底层
Write-Host "==> [1/4] 编译 Rust 底层"
Push-Location "$root\native"
cargo build --release
if ($LASTEXITCODE -ne 0) { throw "Rust 编译失败" }
Pop-Location

# 2. 生成 Flutter Windows 平台目录（已存在则跳过）
Write-Host "==> [2/4] 准备 Flutter 工程"
Push-Location "$root\app"
if (-not (Test-Path "windows")) {
    flutter create --platforms=windows .
    if ($LASTEXITCODE -ne 0) { throw "flutter create 失败" }
}

Write-Host "==> [3/4] 拉取依赖"
flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get 失败" }
Pop-Location

# 3. 打包
Write-Host "==> [4/4] 打包 Windows Release"
Push-Location "$root\app"
flutter build windows --enable-impeller
if ($LASTEXITCODE -ne 0) { throw "Flutter 打包失败" }

$out = "$root\app\build\windows\x64\runner\Release"
Copy-Item "$root\native\target\release\toolkit_native.dll" $out -Force
# MCP 只读服务端：给 Claude / Cursor 等 AI 客户端拉起
Copy-Item "$root\native\target\release\qw_mcp.exe" $out -Force
# Flutter 工程名还是 system_toolbox，产物叫 system_toolbox.exe；
# 安装器/快捷方式/自启动都按 QWGuard.exe 找，这里统一改名。
if (Test-Path "$out\system_toolbox.exe") {
    Rename-Item "$out\system_toolbox.exe" "QWGuard.exe" -Force
}
# 内置引擎与运行库工具要跟着 exe 走
foreach ($d in @('runtime', 'yara')) {
    $src = Join-Path $root "vendor\$d"
    if (Test-Path $src) {
        Copy-Item $src -Destination (Join-Path $out $d) -Recurse -Force
    } else {
        Write-Warning "vendor\$d 不存在"
    }
}
# 生成安装完整性清单：安装器会校验「清单内哈希 + 不允许清单外文件」
& "$root\build_manifest.ps1" -Dir $out

Write-Host "==> 完成：$out"
Write-Host "==> 可执行文件：$out\QWGuard.exe"
Pop-Location
