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
use std::sync::{Mutex, OnceLock};
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
/// 微软官方 DirectX Web 安装器：DirectX Repair 不在时的官方兜底，只 288KB
const DXWEB: &str = "dxwebsetup.exe";

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

/// DirectX 工具：优先 DirectX Repair（离线、能修文件），退回微软官方 dxwebsetup（联网装）
/// 返回 (路径, 是否官方 web 安装器)
fn find_dx() -> Option<(PathBuf, bool)> {
    if let Some(p) = find_tool(&DX_NAMES) {
        return Some((p, false));
    }
    find_tool(&[DXWEB]).map(|p| (p, true))
}

/// DirectX Repair 自带的数据包目录（Data/A = 32 位，Data/B = 64 位）
/// 它的「扫描判断」本质就是拿这两个目录的清单去比对系统目录，
/// 这里直接复用它这套清单，和下面的自研 DLL 检测互相印证。
fn dx_data_dirs() -> Option<(PathBuf, PathBuf)> {
    for d in tool_dirs() {
        let a = d.join("Data").join("A");
        let b = d.join("Data").join("B");
        if a.is_dir() && b.is_dir() {
            return Some((a, b));
        }
    }
    None
}

/// 比对结果缓存 30 秒：连点两次「运行库补全」不用把 260 个 DLL 重新 stat 一遍
static DX_DATA_CACHE: Mutex<Option<(Instant, Vec<String>, Vec<String>)>> = Mutex::new(None);

/// 按 DirectX Repair 的清单比对系统目录，返回 (缺的 32 位, 缺的 64 位)
/// 64 位系统上 32 位组件落在 SysWOW64，64 位组件落在 System32
fn dx_missing_by_data() -> (Vec<String>, Vec<String>) {
    // 开发机（非 Windows）不比对，否则会把清单全判成缺失
    if !cfg!(windows) {
        return (Vec::new(), Vec::new());
    }
    if let Ok(g) = DX_DATA_CACHE.lock() {
        if let Some((t, a, b)) = g.as_ref() {
            if t.elapsed() < Duration::from_secs(30) {
                return (a.clone(), b.clone());
            }
        }
    }

    let mut m32 = Vec::new();
    let mut m64 = Vec::new();
    if let Some((a, b)) = dx_data_dirs() {
        let root = std::env::var("SystemRoot")
            .or_else(|_| std::env::var("windir"))
            .unwrap_or_else(|_| r"C:\Windows".to_string());
        let sys32 = PathBuf::from(&root).join("System32");
        let wow64 = PathBuf::from(&root).join("SysWOW64");

        let collect = |dir: &Path, target: &Path, out: &mut Vec<String>| {
            if let Ok(rd) = fs::read_dir(dir) {
                for e in rd.flatten() {
                    let name = e.file_name().to_string_lossy().to_string();
                    if !name.to_lowercase().ends_with(".dll") {
                        continue;
                    }
                    if !target.join(&name).exists() {
                        out.push(name);
                    }
                }
            }
        };
        collect(&a, &wow64, &mut m32);
        collect(&b, &sys32, &mut m64);

        // 只回前 40 个，界面不用看全量
        m32.truncate(40);
        m64.truncate(40);
    }

    if let Ok(mut g) = DX_DATA_CACHE.lock() {
        *g = Some((Instant::now(), m32.clone(), m64.clone()));
    }
    (m32, m64)
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

/// 系统目录只解析一次，后面每查一个 DLL 都复用，省掉重复读环境变量和拼路径
static SYS_DIRS: OnceLock<Vec<PathBuf>> = OnceLock::new();

fn sys_dirs() -> &'static Vec<PathBuf> {
    SYS_DIRS.get_or_init(|| {
        let mut v = Vec::new();
        for key in ["SystemRoot", "windir"] {
            if let Ok(root) = std::env::var(key) {
                v.push(PathBuf::from(&root).join("System32"));
                v.push(PathBuf::from(&root).join("SysWOW64"));
            }
        }
        // 非 Windows（开发机上跑测试）给个占位，避免空数组
        if v.is_empty() {
            v.push(PathBuf::from("/usr/lib"));
        }
        v
    })
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

    // 第二重判定：拿 DirectX Repair 自带 Data 清单比对系统目录
    let (m32, m64) = dx_missing_by_data();
    let dx_data_missing = m32.len() + m64.len();
    let dx_data_ready = dx_data_dirs().is_some();

    let need_vc = items
        .iter()
        .any(|i| !i.ok && i.key != "dx9" && i.key != "xinput" && i.key != "d3dcompiler");
    let need_dx = items
        .iter()
        .any(|i| !i.ok && matches!(i.key, "dx9" | "xinput" | "d3dcompiler"))
        || dx_data_missing > 0;

    let complete = missing.is_empty() && dx_data_missing == 0;

    ok(
        buf,
        len,
        if complete { "运行库完整" } else { "发现缺失的运行库" },
        serde_json::json!({
            "items": items,
            "total": total,
            "ok_count": ok_count,
            "missing": missing,
            "need_vc": need_vc,
            "need_dx": need_dx,
            // 自研 DLL 检测 + DirectX Repair 自带清单，两重结果都给前端
            "dx_data_ready": dx_data_ready,
            "dx_data_missing": dx_data_missing,
            "dx_data_32": m32,
            "dx_data_64": m64,
            "vc_tool": find_tool(&[VCREDIST]).map(|p| p.to_string_lossy().to_string()),
            "dx_tool": find_dx().map(|(p, _)| p.to_string_lossy().to_string()),
        }),
    )
}

// ============ 工具本体校验 ============

/// tools.json 格式：{"VisualCppRedist_AIO_x86_x64.exe":"<sha256>", "DirectX Repair.exe":"<sha256>"}
fn sha256_file(path: &Path) -> Option<String> {
    use sha2::{Digest, Sha256};
    use std::io::Read as _;
    // 分块读，不再把 32MB 的 AIO 整个读进内存
    let mut f = fs::File::open(path).ok()?;
    let mut buf = [0u8; 64 * 1024];
    let mut h = Sha256::new();
    loop {
        let n = f.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
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
    let dx = find_dx().map(|(p, _)| p);

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

/// 日志超过 2MB 只留尾部 200KB，防止一年年累积把用户磁盘写满
fn trim_log(path: &Path) {
    let Ok(meta) = fs::metadata(path) else { return };
    if meta.len() <= 2 * 1024 * 1024 {
        return;
    }
    if let Ok(text) = fs::read_to_string(path) {
        let total = text.chars().count();
        let tail: String = text
            .chars()
            .skip(total.saturating_sub(200 * 1024))
            .collect();
        let _ = fs::write(path, format!("（日志过长，只保留尾部）\n{tail}"));
    }
}

/// 跑一个子进程并等它结束，输出写日志。返回 exit code
/// 带超时：安装器卡住就 kill 掉，别把后台线程永久挂死
fn run_tool(exe: &Path, args: &[&str], log_name: &str, timeout: Duration) -> Result<i32, String> {
    use std::io::{Read as _, Write as _};
    let lp = log_path();
    trim_log(&lp);
    let mut log = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&lp)
        .map_err(|e| format!("日志打不开: {e}"))?;
    let _ = writeln!(log, "\n=== {log_name} | {} | args={:?}", exe.display(), args);

    let mut cmd = crate::proc::cmd(exe);
    cmd.args(args)
        .current_dir(exe.parent().unwrap_or(Path::new(".")))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);

    let mut child = cmd.spawn().map_err(|e| format!("启动失败: {e}"))?;

    // 起两个线程把管道读空，否则输出一多子进程会卡在写管道上
    let so = child.stdout.take();
    let se = child.stderr.take();
    let th_out = so.map(|mut s| {
        std::thread::spawn(move || {
            let mut b = Vec::new();
            let _ = s.read_to_end(&mut b);
            b
        })
    });
    let th_err = se.map(|mut s| {
        std::thread::spawn(move || {
            let mut b = Vec::new();
            let _ = s.read_to_end(&mut b);
            b
        })
    });

    // 轮询等结果，超时就 kill
    let t0 = Instant::now();
    let mut timed_out = false;
    let status = loop {
        match child.try_wait() {
            Ok(Some(st)) => break Some(st),
            Ok(None) => {
                if t0.elapsed() > timeout {
                    let _ = child.kill();
                    let _ = child.wait();
                    timed_out = true;
                    break None;
                }
                std::thread::sleep(Duration::from_millis(500));
            }
            Err(e) => return Err(format!("等待失败: {e}")),
        }
    };

    let out = th_out.and_then(|h| h.join().ok()).unwrap_or_default();
    let err = th_err.and_then(|h| h.join().ok()).unwrap_or_default();
    let _ = writeln!(log, "{}", String::from_utf8_lossy(&out));
    let _ = writeln!(log, "{}", String::from_utf8_lossy(&err));
    if timed_out {
        let _ = writeln!(log, "超时（{}s）已终止", timeout.as_secs());
    }
    let code = status.and_then(|s| s.code()).unwrap_or(-1);
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
            let Some((p, is_web)) = find_dx() else { continue };
            if !verify_tool(&p).0 {
                *EXIT_CODE.lock().unwrap() = Some(-2);
                continue;
            }
            // DirectX Repair 走 /silent /nosound：不弹它自己的窗口、不响提示音
            // 微软官方 dxwebsetup 走 /q
            let label = if is_web { "DirectX 官方安装器" } else { "DirectX Repair" };
            let args = if is_web { vec!["/q"] } else { vec!["/silent", "/nosound"] };
            (p, args, label)
        };

        *LAST_TOOL.lock().unwrap() = Some(label.to_string());
        // VC++ 全量装慢，给 20 分钟；DirectX 15 分钟，超时就当失败
        let timeout = if *step == "vc" {
            Duration::from_secs(20 * 60)
        } else {
            Duration::from_secs(15 * 60)
        };
        let code = run_tool(&exe, &args, label, timeout).unwrap_or(-1);
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
        if find_dx().is_none() {
            return fail(buf, len, -3, "没找到 DirectX 修复工具，请确认安装完整");
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
