# 系统工具箱 —— Windows 一键构建脚本
# 用法：在项目根目录执行  powershell -ExecutionPolicy Bypass -File .\build_windows.ps1

$ErrorCost = "Stop"
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
# 内置引擎与运行库工具要跟着 exe 走
foreach ($d in @('runtime', 'yara')) {
    $src = Join-Path $root "vendor\$d"
    if (Test-Path $src) {
        Copy-Item $src -Destination (Join-Path $out $d) -Recurse -Force
    } else {
        Write-Warning "vendor\$d 不存在"
    }
}
Write-Host "==> 完成：$out"
Write-Host "==> 可执行文件：$out\system_toolbox.exe"
Pop-Location
