//! 运行库补全（工具箱第十个工具）
//!
//! 定位：检查本机 VC++ / DirectX 运行库是否完整，缺了就补。
//! 底层用两个内置工具，不自己写安装逻辑：
//!   - VisualCppRedist AIO（abbodi1406/vcredist，GitHub 开源）→ 管 VC++ 全套
//!   - DirectX Repair（原版 exe，只外部调用，不拆不改）→ 只管 DirectX 组件
//!
//! 分工是硬性的：VC++ 一律交给 AIO，DirectX Repair 只处理 d3d/dx 那部分，
//! 避免两个工具同时动 VC++ 的注册表互相打架。
//!
//! 两个 exe 放在 <安装目录>/runtime/ 下，由安装器释放；
//! 每次执行前比对该目录下 tools.json 里的 sha256，被换过就拒绝执行。

use crate::{cstr, fail, ok, round1};
use serde::Serialize;
use std::ffi::c_char;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

#[cfg(windows)]
use std::os::windows::process::CommandExt;
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// VC++ AIO 的固定文件名（GitHub 上就是这个名字，别改）
const VCREDIST: &str = "VisualCppRedist_AIO_x86_x64.exe";
/// DirectX Repair 各家下载站文件名不统一，按候选顺序找
const DX_NAMES: [&str; 4] = [
    "DirectX Repair.exe",
    "DirectX_Repair.exe",
    "DirectXRepair.exe",
    "DirectX Repair (Enhanced Edition).exe",
];

/// 后台修复状态
static FIXING: AtomicBool = AtomicBool::new(false);
static LAST_MODE: Mutex<Option<String>> = Mutex::new(None);
static EXIT_CODE: Mutex<Option<i32>> = Mutex::new(None);
static LAST_TOOL: Mutex<Option<String>> = Mutex::new(None);

fn app_dir() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|x| x.to_path_buf()))
        .unwrap_or_else(|| PathBuf::from("."))
}

/// 工具可能在这几个位置，依次找
fn tool_dirs() -> Vec<PathBuf> {
    let base = app_dir();
    vec![
        base.join("runtime"),
        base.join("tools"),
        base.join("bundle").join("runtime"),
        base.join("data").join("runtime"),
    ]
}

fn find_tool(names: &[&str]) -> Option<PathBuf> {
    for d in tool_dirs() {
        for n in names {
            let p = d.join(n);
            if p.is_file() {
                return Some(p);
            }
        }
    }
    None
}

// ============ 运行库检测 ============

/// 一项运行库：看关键 DLL 在不在
#[derive(Serialize)]
struct LibItem {
    key: &'static str,
    name: &'static str,
    dll: &'static str,
    ok: bool,
}

/// 要查的清单。DLL 名是这个版本独有的，有就等于装了。
const LIBS: [(&str, &str, &str); 12] = [
    ("vc2005", "VC++ 2005", "msvcr80.dll"),
    ("vc2008", "VC++ 2008", "msvcr90.dll"),
    ("vc2010", "VC++ 2010", "msvcr100.dll"),
    ("vc2012", "VC++ 2012", "msvcr110.dll"),
    ("vc2013", "VC++ 2013", "msvcr120.dll"),
    ("vc2015", "VC++ 2015-2026", "msvcp140.dll"),
    ("vcruntime", "VC++ 运行库核心", "vcruntime140.dll"),
    ("ucrt", "Universal CRT", "ucrtbase.dll"),
    ("vb6", "VB 运行库", "msvbvm60.dll"),
    ("dx9", "DirectX 9 组件", "d3dx9_43.dll"),
    ("xinput", "XInput 手柄组件", "xinput1_3.dll"),
    ("d3dcompiler", "D3D 着色器编译", "d3dcompiler_47.dll"),
];

fn sys_dirs() -> Vec<PathBuf> {
    let mut v = Vec::new();
    for key in ["SystemRoot", "windir"] {
        if let Ok(root) = std::env::var(key) {
            v.push(PathBuf::from(&root).join("System32"));
            v.push(PathBuf::from(&root).join("SysWOW64"));
        }
    }
    // 非 Windows（开发机上跑测试）给几个常见位置，避免直接空数组
    v.push(PathBuf::from("/usr/lib"));
    v
}

fn dll_exists(name: &str) -> bool {
    sys_dirs().iter().any(|d| d.join(name).is_file())
}

#[no_mangle]
pub extern "C" fn runtime_scan(buf: *mut u8, len: usize) -> i32 {
    let items: Vec<LibItem> = LIBS
        .iter()
        .map(|(k, n, d)| LibItem {
            key: *k,
            name: *n,
            dll: *d,
            ok: dll_exists(*d),
        })
        .collect();

    let missing: Vec<&str> = items.iter().filter(|i| !i.ok).map(|i| i.name).collect();
    let total = items.len();
    let ok_count = total - missing.len();

    ok(
        buf,
        len,
        if missing.is_empty() { "运行库完整" } else { "发现缺失的运行库" },
        serde_json::json!({
            "items": items,
            "total": total,
            "ok_count": ok_count,
            "missing": missing,
            "need_vc": items.iter().any(|i| !i.ok && i.key != "dx9" && i.key != "xinput" && i.key != "d3dcompiler"),
            "need_dx": items.iter().any(|i| !i.ok && matches!(i.key, "dx9" | "xinput" | "d3dcompiler")),
            "vc_tool": find_tool(&[VCREDIST]).map(|p| p.to_string_lossy().to_string()),
            "dx_tool": find_tool(&DX_NAMES).map(|p| p.to_string_lossy().to_string()),
        }),
    )
}

// ============ 工具本体校验 ============

/// tools.json 格式：{"VisualCppRedist_AIO_x86_x64.exe":"<sha256>", "DirectX Repair.exe":"<sha256>"}
fn sha256_file(path: &Path) -> Option<String> {
    use sha2::{Digest, Sha256};
    let data = fs::read(path).ok()?;
    let mut h = Sha256::new();
    h.update(&data);
    Some(format!("{:x}", h.finalize()))
}

/// 返回 (可用, 说明)。没 manifests 时放行但在说明里写清楚"未校验"
fn verify_tool(path: &Path) -> (bool, String) {
    let Some(dir) = path.parent() else {
        return (false, "路径异常".into());
    };
    let manifest = dir.join("tools.json");
    let Ok(text) = fs::read_to_string(&manifest) else {
        return (true, "未提供校验清单，跳过哈希比对".into());
    };
    let Ok(map) = serde_json::from_str::<serde_json::Value>(&text) else {
        return (true, "校验清单格式不对，跳过哈希比对".into());
    };
    let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
        return (false, "文件名异常".into());
    };
    let Some(want) = map.get(name).and_then(|v| v.as_str()) else {
        return (true, "清单里没登记这个文件，跳过哈希比对".into());
    };
    let Some(got) = sha256_file(path) else {
        return (false, "读取文件失败".into());
    };
    if got.eq_ignore_ascii_case(want) {
        (true, "哈希校验通过".into())
    } else {
        (false, "文件哈希与清单不一致，可能被替换过，已拒绝执行".into())
    }
}

#[no_mangle]
pub extern "C" fn runtime_tools(buf: *mut u8, len: usize) -> i32 {
    let vc = find_tool(&[VCREDIST]);
    let dx = find_tool(&DX_NAMES);

    let vc_info = vc.as_ref().map(|p| {
        let (good, msg) = verify_tool(p);
        let mb = fs::metadata(p).map(|m| round1(m.len() as f32 / 1048576.0)).unwrap_or(0.0);
        serde_json::json!({
            "name": p.file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default(),
            "path": p.to_string_lossy(),
            "size_mb": mb,
            "verified": good,
            "note": msg,
        })
    });

    let dx_info = dx.as_ref().map(|p| {
        let (good, msg) = verify_tool(p);
        let mb = fs::metadata(p).map(|m| round1(m.len() as f32 / 1048576.0)).unwrap_or(0.0);
        serde_json::json!({
            "name": p.file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default(),
            "path": p.to_string_lossy(),
            "size_mb": mb,
            "verified": good,
            "note": msg,
        })
    });

    let all_ok = vc_info.is_some() && dx_info.is_some();
    ok(
        buf,
        len,
        if all_ok { "两个修复工具就位" } else { "修复工具不全" },
        serde_json::json!({
            "vcredist": vc_info,
            "dxrepair": dx_info,
            "all_ok": all_ok,
            "dir": tool_dirs().first().map(|p| p.to_string_lossy().to_string()),
        }),
    )
}

// ============ 执行修复 ============

fn log_path() -> PathBuf {
    let dir = crate::ext::cfg_dir();
    let _ = fs::create_dir_all(&dir);
    dir.join("runtime.log")
}

/// 跑一个子进程并等它结束，输出写日志。返回 exit code
fn run_tool(exe: &Path, args: &[&str], log_name: &str) -> Result<i32, String> {
    use std::io::Write as _;
    let mut log = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path())
        .map_err(|e| format!("日志打不开: {e}"))?;
    let _ = writeln!(log, "\n=== {log_name} | {} | args={:?}", exe.display(), args);

    let mut cmd = Command::new(exe);
    cmd.args(args)
        .current_dir(exe.parent().unwrap_or(Path::new(".")))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);

    let child = cmd.spawn().map_err(|e| format!("启动失败: {e}"))?;
    let out = child.wait_with_output().map_err(|e| format!("等待失败: {e}"))?;

    let _ = writeln!(log, "{}", String::from_utf8_lossy(&out.stdout));
    let _ = writeln!(log, "{}", String::from_utf8_lossy(&out.stderr));
    let code = out.status.code().unwrap_or(-1);
    let _ = writeln!(log, "exit = {code}");
    Ok(code)
}

/// 后台跑：先 VC++ 再 DirectX，串行，避免两个安装器抢注册表
fn run_all(mode: String) {
    *LAST_MODE.lock().unwrap() = Some(mode.clone());
    *EXIT_CODE.lock().unwrap() = None;
    *LAST_TOOL.lock().unwrap() = None;
    FIXING.store(true, Ordering::SeqCst);

    let steps: &[&str] = match mode.as_str() {
        "vc" => &["vc"],
        "dx" => &["dx"],
        _ => &["vc", "dx"],
    };

    for step in steps {
        let (exe, args, label) = if *step == "vc" {
            let Some(p) = find_tool(&[VCREDIST]) else { continue };
            if !verify_tool(&p).0 {
                *EXIT_CODE.lock().unwrap() = Some(-2);
                continue;
            }
            // /ai = 静默装全部；AIO 自己会先清掉不合规的旧版
            (p, vec!["/ai"], "VisualCppRedist AIO")
        } else {
            let Some(p) = find_tool(&DX_NAMES) else { continue };
            if !verify_tool(&p).0 {
                *EXIT_CODE.lock().unwrap() = Some(-2);
                continue;
            }
            // DirectX Repair 的静默开关
            (p, vec!["/silent"], "DirectX Repair")
        };

        *LAST_TOOL.lock().unwrap() = Some(label.to_string());
        let code = run_tool(&exe, &args, label).unwrap_or(-1);
        *EXIT_CODE.lock().unwrap() = Some(code);
    }

    FIXING.store(false, Ordering::SeqCst);
    crate::bg_log(&format!("运行库补全结束，mode={mode}"));
}

#[no_mangle]
pub extern "C" fn runtime_fix(mode: *const c_char, buf: *mut u8, len: usize) -> i32 {
    let Some(mode) = cstr(mode) else { return fail(buf, len, -1, "参数为空") };
    let m = match mode.as_str() {
        "vc" | "dx" | "all" => mode,
        _ => return fail(buf, len, -1, "mode 只能是 vc / dx / all"),
    };
    if FIXING.load(Ordering::SeqCst) {
        return fail(buf, len, -3, "已经在修了，等这一轮跑完");
    }

    // 开工前先把工具检查一遍，缺了直接报，不要装作能修
    if m == "vc" || m == "all" {
        if find_tool(&[VCREDIST]).is_none() {
            return fail(buf, len, -3, "没找到 VisualCppRedist AIO，请确认安装完整");
        }
    }
    if m == "dx" || m == "all" {
        if find_tool(&DX_NAMES).is_none() {
            return fail(buf, len, -3, "没找到 DirectX Repair，请确认安装完整");
        }
    }

    let mode2 = m.clone();
    std::thread::spawn(move || run_all(mode2));

    ok(
        buf,
        len,
        "已开始修复，进度走后台",
        serde_json::json!({ "mode": m, "log": log_path().to_string_lossy() }),
    )
}

#[no_mangle]
pub extern "C" fn runtime_status(buf: *mut u8, len: usize) -> i32 {
    let running = FIXING.load(Ordering::SeqCst);
    let code = *EXIT_CODE.lock().unwrap();
    let mode = LAST_MODE.lock().unwrap().clone();
    let tool = LAST_TOOL.lock().unwrap().clone();

    // 日志尾巴，给界面滚动区显示
    let tail = fs::read_to_string(log_path())
        .map(|s| {
            let lines: Vec<&str> = s.lines().rev().take(12).collect();
            lines.into_iter().rev().collect::<Vec<_>>().join("\n")
        })
        .unwrap_or_default();

    ok(
        buf,
        len,
        "状态读取完成",
        serde_json::json!({
            "running": running,
            "mode": mode,
            "tool": tool,
            "exit_code": code,
            "finished": !running && mode.is_some(),
            "success": code == Some(0),
            "log_tail": tail,
        }),
    )
}

/// 界面启动一个轮询用的轻量等待：给秒数，阻塞最多这么久看是否结束
#[no_mangle]
pub extern "C" fn runtime_wait(secs: i32) -> i32 {
    let deadline = Instant::now() + Duration::from_secs(secs.clamp(0, 30) as u64);
    while Instant::now() < deadline {
        if !FIXING.load(Ordering::SeqCst) {
            return 1;
        }
        std::thread::sleep(Duration::from_millis(300));
    }
    0
}
