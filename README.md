# QW 电脑安全管家（Windows）

Flutter（UI）+ Impeller（渲染）+ Rust（底层 DLL）实现的 Windows 安全管家。

目录：
- `app/` Flutter 工程（Dart 代码已完成，平台目录需在 Windows 上生成）
- `native/` Rust 底层（已编译验证，导出 7 个 FFI 函数）
- `build_windows.ps1` 一键构建脚本
- `build_installer.ps1` + `installer/setup.iss` 打 EXE 安装包（卸载清残留）
- `系统工具箱_需求与方案汇总.md` 需求与技术方案

---

## 一、当前完成情况

### Rust 底层（已实测）

`native` 已在本机 `cargo build --release` 通过，并用 ctypes 调用验证：

```
ping            -> 20261120        自检通过
get_hardware_info -> 0             真实读到 CPU 型号/负载/内存/磁盘
scan_cleanup      -> 0             扫出可清理项与体积
execute_cleanup   -> 0             dry-run 模式正常，只统计不删除
```

导出函数：

| 函数 | 说明 |
|---|---|
| `ping()` | 自检，返回固定值 20261120 |
| `get_hardware_info(buf, len)` | 硬件 JSON；温度取不到则**不输出该字段** |
| `scan_cleanup(buf, len)` | 清理扫描，返回分类/路径/体积/是否默认勾选 |
| `execute_cleanup(json, dry_run)` | 执行清理；含系统关键目录护栏 |
| `scan_file(engine, path, buf, len)` | 调 Defender / ClamAV / YARA 命令行 |
| `launch_external(name, buf, len)` | 唤起火绒 / PYAS |

约束：
- 返回 0 成功、-1 参数错、-2 缓冲区不足、-3 执行失败
- 缓冲区内为 UTF-8 JSON，末尾自动补 `\0`

### Flutter 界面（代码已完成，未在本机编译）

- iOS 27 液态玻璃材质，浅色/深色两套同一套玻璃逻辑
- 澎湃 OS 4 布局：大圆角、宽留白、侧边栏展开/收起、页面切换缩放淡入
- 弥散光斑随明暗切换配色
- 首次启动引导：浅色 / 深色 / 跟随系统 + 中英文切换（默认中文）
- 四个页面：硬件检测、系统清理（勾选 + 预演 + 二次确认）、病毒查杀、工具合集
- FFI 全部走 `Native` 桥，DLL 缺失时界面不崩，返回可读错误
- 悬浮玻璃 Dock、粒子层、折射层（边缘色散 + 扫光 + 镜面高光）
- 无边框圆角窗口（window_manager）+ 自绘标题栏
- 悬浮监控浮层（CPU/内存/GPU/温度/NPU，DIY，默认关）
- 桌面级置顶监控窗口：`desktop_multi_window` 第二引擎窗口 + Rust `set_topmost`（已交叉检查 Windows 目标编译）
- 三语言：简体（默认）/ 繁體 / English
- 五引擎：Defender / ClamAV / YARA-X / 火绒 / PYAS（后两者为外部集成，PYAS 为日志 best-effort）
- 智能查杀：按显卡强弱选策略（独显→三引擎并发，核显→轻量 Defender），开关默认开
- 动画全部可在设置关闭，默认全开：玻璃、实时模糊、折射、扫光带、粒子、光斑漂浮、Dock 弹簧、页面切换、按钮按压、卡片入场

> 本机是 Linux 且无 Flutter SDK，Flutter 部分只做了代码编写，**没有编译验证**。首次在 Windows 上跑如遇 API 差异，改一两行即可。

---

## 二、在 Windows 上跑起来

### 1. 环境
- Flutter SDK（3.19+，开启 Windows 桌面支持）
- Visual Studio 2022 + C++ 桌面开发组件
- Rust（stable，`x86_64-pc-windows-msvc`）

### 2. 生成 Windows 平台目录

```powershell
cd app
flutter create --platforms=windows .
```
该命令只补 `windows/` 等平台目录，不会覆盖 `lib/`。

### 3. 编译 Rust

```powershell
cd ..\native
cargo build --release
copy target\release\toolkit_native.dll ..\app\build\windows\x64\runner\Release\
```

### 4. 运行 / 打包

```powershell
cd ..\app
flutter run -d windows --enable-impeller
flutter build windows --enable-impeller
```

或直接跑根目录的 `build_windows.ps1`。

---

## 三、已知限制（诚实说明）

1. **Mica 云母**：用 `flutter_acrylic` 调用；若云母透不出来，说明 runner 需要透明化处理，此时界面会退回自带的渐变背景（不影响功能）。Win10 自动退回普通背景。
2. **硬件温度**：依赖系统传感器接口，桌面机/虚拟机常常拿不到。拿不到时字段直接不输出，界面不显示该项（符合需求）。
3. **ClamAV / YARA**：走命令行子进程，需本机安装或随包附带 `clamscan.exe` / `yara-x.exe`；否则返回「未找到」提示。
4. **PYAS**：没有命令行与 SDK，只能唤起主程序，拿不到扫描结果回传。
5. **火绒**：`hrscan.exe` 路径因版本而异，代码里已列常见路径，找不到时提示未安装。
6. **winapp2.ini**：当前内置了常用规则（Chrome/Edge/Firefox/微信/QQ），如需全量规则库，把 `winapp2.ini` 解析器接进 Rust 即可。

---

## 四、下一步

1. 在 Windows 上跑通 UI（`flutter create` + `cargo build`）
2. 补 winapp2.ini 全量规则解析
3. 加文件/目录选择器（`file_selector`），扫描路径不用手输
4. 加扫描进度回传（Rust 侧回调 → Dart）
5. Inno Setup 打 `setup.exe`

## 运行库补全（工具箱第十个工具）

工具箱里的「运行库补全」先扫本机 VC++ / DirectX 组件，缺什么补什么。

两个底层工具都是原版，不拆不改：

- `VisualCppRedist_AIO_x86_x64.exe` —— abbodi1406/vcredist，GitHub 开源，管 VC++ 2002~2026 全套 + VB 运行库 + UCRT；静默参数 `/ai`
- `DirectX Repair.exe` —— 原版 exe，只外部调用，管 DirectX 9 / XInput / 着色器编译组件；静默参数 `/silent`

放在 `vendor/runtime/`，安装时复制到 `<安装目录>/runtime/`。

该目录可放一个 `tools.json` 登记哈希，有清单就严格比对、对不上拒绝执行，没清单放行但提示未校验：

    {
      "VisualCppRedist_AIO_x86_x64.exe": "<sha256>",
      "DirectX Repair.exe": "<sha256>"
    }

分工：VC++ 一律走 AIO，DirectX 走 Repair，两边不重叠，避免抢注册表。

---

## 借鉴与致谢

谢谢下面这些团队的支持：

- **Windows Defender 查杀引擎** — Microsoft · 命令行 MpCmdRun
- **ClamAV 病毒扫描** — Cisco Talos · https://github.com/Cisco-Talos/clamav
- **YARA-X 规则引擎** — VirusTotal · https://github.com/VirusTotal/yara-x
- **火绒安全 hrscan** — 火绒安全 · https://www.huorong.cn
- **PYAS 引擎** — 外部集成，日志回传
- **VisualCppRedist AIO**（VC++ 2002~2026 全套 + VB6 + UCRT）— abbodi1406 · https://github.com/abbodi1406/vcredist
- **DirectX Repair 增强版**（DirectX 9 / XInput / 着色器编译组件修复）— zysoftware · https://www.zysoftware.top
- **Flutter / Rust** — 界面与底层框架

漏了谁、写错了谁，提 issue，我立刻补上。

---

**酷安作者账号：QW123456780**

---

### 支持作者

作者制作维护不容易，爱心捐款，一杯奶茶价钱，就是作者继续维护更新的动力。

<img src="app/assets/donate_qr.png" alt="微信赞赏码" width="240">
