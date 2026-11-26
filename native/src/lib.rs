//! QW 安全电脑管家 —— Rust 底层（FFI 导出）
//!
//! 统一约定：
//! - 结果为 UTF-8 JSON，写入调用方缓冲区，末尾补 '\0'
//! - 返回：0 成功 / -1 参数错 / -2 缓冲区不足 / -3 执行失败

use rayon::prelude::*;
use serde::Serialize;
use serde_json::Value;
use std::ffi::{c_char, CStr};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use sysinfo::{Components, Disks, System};

// ---- 清理扫描实时进度（前端轮询，画文件名滚动用） ----
static CLEAN_RUNNING: AtomicBool = AtomicBool::new(false);
static CLEAN_FILES: AtomicU64 = AtomicU64::new(0);
static CLEAN_BYTES: AtomicU64 = AtomicU64::new(0);
static CLEAN_CUR: Mutex<String> = Mutex::new(String::new());

mod engines;
pub mod ext;
mod installer;

/// FFI 边界 panic 屏障：任何内部 panic 都转成 -4，绝不让整个进程 abort。
#[macro_export]
macro_rules! ffi_guard {
    ($buf:expr, $len:expr, $body:block) => {
        match ::std::panic::catch_unwind(::std::panic::AssertUnwindSafe(|| $body)) {
            Ok(__r) => __r,
            Err(_) => $crate::fail($buf, $len, -4, "内部错误：已拦截，未崩溃"),
        }
    };
}

/// 无缓冲区参数的导出函数用这个（如 ping / runtime_wait）
#[macro_export]
macro_rules! ffi_guard_none {
    ($body:block) => {
        match ::std::panic::catch_unwind(::std::panic::AssertUnwindSafe(|| $body)) {
            Ok(__r) => __r,
            Err(_) => -4,
        }
    };
}

mod proc;
pub mod quarantine;
mod runtime;
pub mod security;
mod tools;
#[cfg(windows)]
mod topmost;
mod util;

pub(crate) fn respond(
    buf: *mut u8,
    len: usize,
    ok: bool,
    code: i32,
    msg: &str,
    data: Value,
) -> i32 {
    if buf.is_null() || len == 0 {
        return -1;
    }
    let payload = serde_json::json!({
        "success": ok,
        "code": code,
        "message": msg,
        "data": data,
    });
    let text = payload.to_string();
    let bytes = text.as_bytes();
    if bytes.len() + 1 > len {
        return -2;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf, bytes.len());
        *buf.add(bytes.len()) = 0;
    }
    0
}

pub(crate) fn ok<T: Serialize>(buf: *mut u8, len: usize, msg: &str, data: T) -> i32 {
    respond(
        buf,
        len,
        true,
        0,
        msg,
        serde_json::to_value(data).unwrap_or(Value::Null),
    )
}

pub(crate) fn fail(buf: *mut u8, len: usize, code: i32, msg: &str) -> i32 {
    // 缓冲区太小要按约定回 -2，而不是把业务错误码盖回去
    if respond(buf, len, false, code, msg, Value::Null) == -2 {
        return -2;
    }
    code
}

/// 原子写：先落 .tmp 再 rename，断电也不会留下半截 JSON
pub(crate) fn write_atomic(path: &Path, text: &str) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    fs::write(&tmp, text)?;
    fs::rename(&tmp, path)
}

pub(crate) fn cstr(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p).to_str().ok().map(str::to_string) }
}

pub(crate) fn round1(v: f32) -> f32 {
    (v * 10.0).round() / 10.0
}

/// 展开 %VAR% / $VAR / ~ 路径
pub(crate) fn expand(raw: &str) -> Option<PathBuf> {
    let mut s = raw.to_string();
    while let Some(start) = s.find('%') {
        let Some(rel) = s[start + 1..].find('%') else {
            break;
        };
        let end = start + 1 + rel;
        let val = std::env::var(&s[start + 1..end]).ok()?;
        s = format!("{}{}{}", &s[..start], val, &s[end + 1..]);
    }
    if let Some(rest) = s.strip_prefix('$') {
        if let Some(i) = rest.find('/') {
            s = format!("{}{}", std::env::var(&rest[..i]).ok()?, &rest[i..]);
        }
    }
    if let Some(rest) = s.strip_prefix("~/") {
        let home = std::env::var("HOME")
            .or_else(|_| std::env::var("USERPROFILE"))
            .ok()?;
        s = format!("{}/{}", home, rest);
    }
    let p = PathBuf::from(s);
    p.exists().then_some(p)
}

pub(crate) fn dir_size(path: &Path, depth: usize) -> u64 {
    if depth == 0 {
        return 0;
    }
    let Ok(meta) = fs::symlink_metadata(path) else {
        return 0;
    };
    if meta.file_type().is_symlink() {
        return 0;
    }
    if meta.is_file() {
        return meta.len();
    }
    fs::read_dir(path)
        .map(|rd| rd.flatten().map(|e| dir_size(&e.path(), depth - 1)).sum())
        .unwrap_or(0)
}

// ============ 文件自保护 ============

/// 运行期间占住安装目录里的 exe / dll：以「只允许别人读」的方式打开，
/// 不共享 DELETE。Windows 的删除、改名都要先拿 DELETE 权限，
/// 拿不到就是「文件正在使用」——Explorer、第三方删除工具、copy /y 全部失败，
/// 只有先结束本进程（官方卸载器会做）才解得开。
#[cfg(windows)]
mod protect {
    use std::fs::OpenOptions;
    use std::os::windows::fs::OpenOptionsExt;
    use std::path::Path;

    /// 只给 FILE_SHARE_READ（1）：别人能读、能执行，但拿不到 DELETE 权限，
    /// 删除 / 改名一律失败。句柄一直攥在手里，进程活着就解不开。
    static HELD: std::sync::Mutex<Vec<std::fs::File>> = std::sync::Mutex::new(Vec::new());

    pub fn lock_tree(dir: &Path) -> usize {
        let Ok(rd) = std::fs::read_dir(dir) else {
            return 0;
        };
        let mut n = 0usize;
        for e in rd.flatten() {
            let p = e.path();
            let Ok(md) = std::fs::symlink_metadata(&p) else {
                continue;
            };
            if md.is_dir() {
                n += lock_tree(&p);
                continue;
            }
            let name = e.file_name().to_string_lossy().to_lowercase();
            if !(name.ends_with(".exe") || name.ends_with(".dll")) {
                continue;
            }
            let r = OpenOptions::new()
                .read(true)
                .share_mode(0x0000_0001)
                .open(&p);
            if let Ok(f) = r {
                if let Ok(mut g) = HELD.lock() {
                    g.push(f);
                }
                n += 1;
            }
        }
        n
    }
}

/// 供界面在启动时调一次；重复调用是幂等的（第二次起文件已被自己占用，
/// CreateFileW 仍能以只读共享方式成功，所以计数不会再涨，没有副作用）。
#[no_mangle]
pub extern "C" fn self_protect(buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        #[cfg(windows)]
        {
            let exe = std::env::current_exe().unwrap_or_default();
            let dir = exe.parent().map(|p| p.to_path_buf()).unwrap_or_default();
            let n = protect::lock_tree(&dir);
            return ok(
                buf,
                len,
                "文件自保护已启用",
                serde_json::json!({
                    "locked": n,
                    "dir": dir.to_string_lossy(),
                    "note": "运行期间安装目录内的 exe/dll 无法被删除或改名；官方卸载器会先结束进程再清理"
                }),
            );
        }
        #[cfg(not(windows))]
        {
            ok(
                buf,
                len,
                "文件自保护仅 Windows 有效",
                serde_json::json!({"locked": 0}),
            )
        }
    })
}

// ============ 自检 ============

#[no_mangle]
pub extern "C" fn ping() -> i32 {
    crate::ffi_guard_none!({ 20261120 })
}

// ============ 硬件 ============

#[derive(Serialize, Clone)]
struct Disk {
    name: String,
    total_gb: f32,
    free_gb: f32,
    #[serde(skip_serializing_if = "Option::is_none")]
    media: Option<String>,
}

#[derive(Clone)]
struct HwStatic {
    cpu_name: String,
    cpu_cores: usize,
    mem_total_gb: f32,
    gpus: Vec<ext::Gpu>,
    recommended_gpu: String,
}

static HW_SYS: OnceLock<Mutex<System>> = OnceLock::new();
static HW_STATIC: OnceLock<HwStatic> = OnceLock::new();
static HW_DISKS: OnceLock<Mutex<(u64, Vec<Disk>)>> = OnceLock::new();
static HW_TEMPS: OnceLock<Mutex<(u64, Option<f32>, Option<f32>, Option<f32>)>> = OnceLock::new();

/// 只初始化一次 System：new_all 会枚举 CPU、内存、进程等，监控窗口每 1.6 秒
/// 重建一次纯属浪费。后续只刷新 CPU 占用和内存使用。
fn hw_system() -> &'static Mutex<System> {
    HW_SYS.get_or_init(|| Mutex::new(System::new_all()))
}

fn hw_static() -> &'static HwStatic {
    HW_STATIC.get_or_init(|| {
        let sys = hw_system().lock().unwrap_or_else(|e| e.into_inner());
        let mut cpu_name = sys
            .cpus()
            .first()
            .map(|c| c.brand().trim().to_string())
            .unwrap_or_default();
        let mut cpu_cores = sys.cpus().len();
        // sysinfo 偶尔拿不到型号/核心数，退回 Windows CIM（只查一次，之后缓存）
        if cpu_name.is_empty() || cpu_cores == 0 {
            if let Some((n, c)) = ext::ps_cpu() {
                if cpu_name.is_empty() {
                    cpu_name = n;
                }
                if cpu_cores == 0 {
                    cpu_cores = c;
                }
            }
        }
        if cpu_name.is_empty() {
            cpu_name = "未知处理器".to_string();
        }
        let mem_total_gb = round1(sys.total_memory() as f32 / 1073741824.0);
        drop(sys); // 后面要起 PowerShell 查显卡，别攥着 System 锁等它
        let gpus = ext::detect_gpus();
        let recommended_gpu = ext::recommend_gpu(&gpus);
        HwStatic {
            cpu_name,
            cpu_cores,
            mem_total_gb,
            gpus,
            recommended_gpu,
        }
    })
}

/// 磁盘容量变化慢，30 秒刷新一次足够；避免每个监控 tick 都枚举磁盘 + 查介质类型。
fn hw_disks() -> Vec<Disk> {
    let cache = HW_DISKS.get_or_init(|| Mutex::new((0, Vec::new())));
    let now = util::now_secs();
    let mut g = cache.lock().unwrap_or_else(|e| e.into_inner());
    if g.0 == 0 || now.saturating_sub(g.0) >= 30 {
        let disks: Vec<Disk> = Disks::new_with_refreshed_list()
            .list()
            .iter()
            .map(|d| Disk {
                name: if d.name().is_empty() {
                    d.mount_point().to_string_lossy().into()
                } else {
                    d.name().to_string_lossy().into()
                },
                total_gb: round1(d.total_space() as f32 / 1073741824.0),
                free_gb: round1(d.available_space() as f32 / 1073741824.0),
                media: ext::disk_media(&d.mount_point().to_string_lossy()),
            })
            .collect();
        *g = (now.max(1), disks);
    }
    g.1.clone()
}

/// 温度传感器枚举慢，5 秒刷一次；监控窗口要的是流畅，不是毫秒级温度。
fn hw_temps() -> (Option<f32>, Option<f32>, Option<f32>) {
    let cache = HW_TEMPS.get_or_init(|| Mutex::new((0, None, None, None)));
    let now = util::now_secs();
    let mut g = cache.lock().unwrap_or_else(|e| e.into_inner());
    if g.0 == 0 || now.saturating_sub(g.0) >= 5 {
        let comps = Components::new_with_refreshed_list();
        let (mut cpu, mut gpu, mut disk) = (None, None, None);
        for c in comps.list() {
            let l = c.label().to_lowercase();
            let t = round1(c.temperature());
            if cpu.is_none() && (l.contains("cpu") || l.contains("core")) {
                cpu = Some(t);
            } else if gpu.is_none()
                && (l.contains("gpu") || l.contains("nvidia") || l.contains("radeon"))
            {
                gpu = Some(t);
            } else if disk.is_none()
                && (l.contains("nvme") || l.contains("ssd") || l.contains("hdd"))
            {
                disk = Some(t);
            }
        }
        *g = (now.max(1), cpu, gpu, disk);
    }
    (g.1, g.2, g.3)
}

#[derive(Serialize)]
struct Hardware {
    cpu_name: String,
    cpu_cores: usize,
    cpu_load: f32,
    mem_total_gb: f32,
    mem_used_gb: f32,
    #[serde(skip_serializing_if = "Option::is_none")]
    cpu_temp: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    gpu_temp: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    disk_temp: Option<f32>,
    disks: Vec<Disk>,
    gpus: Vec<ext::Gpu>,
    recommended_gpu: String,
}

#[no_mangle]
pub extern "C" fn get_hardware_info(buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        let stat = hw_static();
        let mut sys = hw_system().lock().unwrap_or_else(|e| e.into_inner());
        // 只刷动态项：CPU 占用和内存使用。CPU 型号/核心数/总内存已经缓存，
        // 不用每次 new_all() 重新枚举整套硬件。
        sys.refresh_cpu_usage();
        sys.refresh_memory();
        let load = round1(sys.global_cpu_info().cpu_usage());
        let used_gb = round1(sys.used_memory() as f32 / 1073741824.0);
        drop(sys);

        let disks = hw_disks();
        let (cpu_temp, gpu_temp, disk_temp) = hw_temps();

        ok(
            buf,
            len,
            "硬件信息读取完成",
            Hardware {
                cpu_name: stat.cpu_name.clone(),
                cpu_cores: stat.cpu_cores,
                cpu_load: load,
                mem_total_gb: stat.mem_total_gb,
                mem_used_gb: used_gb,
                cpu_temp,
                gpu_temp,
                disk_temp,
                disks,
                gpus: stat.gpus.clone(),
                recommended_gpu: stat.recommended_gpu.clone(),
            },
        )
    })
}

/// 监控窗口专用轻量接口：不枚举磁盘、不查介质类型，静态信息进程内缓存。
/// 悬浮窗/桌面监控每 1.6 秒调一次，之前每次都在 UI 线程跑 new_all + PowerShell。
#[no_mangle]
pub extern "C" fn get_hardware_metrics(buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        let stat = hw_static();
        let mut sys = hw_system().lock().unwrap_or_else(|e| e.into_inner());
        sys.refresh_cpu_usage();
        sys.refresh_memory();
        let load = round1(sys.global_cpu_info().cpu_usage());
        let used_gb = round1(sys.used_memory() as f32 / 1073741824.0);
        drop(sys);

        let (cpu_temp, gpu_temp, _) = hw_temps();
        ok(
            buf,
            len,
            "硬件指标读取完成",
            serde_json::json!({
                "cpu_name": stat.cpu_name,
                "cpu_cores": stat.cpu_cores,
                "cpu_load": load,
                "mem_total_gb": stat.mem_total_gb,
                "mem_used_gb": used_gb,
                "memory_total_gb": stat.mem_total_gb,
                "memory_used_gb": used_gb,
                "cpu_temp": cpu_temp,
                "gpu_temp": gpu_temp,
                "gpus": stat.gpus,
                "recommended_gpu": stat.recommended_gpu,
            }),
        )
    })
}

// ============ 清理 ============

#[derive(Serialize)]
struct CleanItem {
    id: String,
    category: String,
    path: String,
    size_bytes: u64,
    default_checked: bool,
    source: String,
}

pub(crate) fn rules() -> Vec<(&'static str, &'static str, &'static str, &'static str)> {
    if cfg!(windows) {
        vec![
            ("win_temp", "%TEMP%", "Windows", "系统临时文件"),
            (
                "local_temp",
                "%LOCALAPPDATA%\\Temp",
                "Windows",
                "系统临时文件",
            ),
            (
                "prefetch",
                "C:\\Windows\\Prefetch",
                "Windows",
                "系统预读缓存",
            ),
            (
                "wer",
                "C:\\ProgramData\\Microsoft\\Windows\\WER",
                "Windows",
                "错误报告",
            ),
            (
                "thumb",
                "%LOCALAPPDATA%\\Microsoft\\Windows\\Explorer",
                "Windows",
                "缩略图缓存",
            ),
            (
                "chrome",
                "%LOCALAPPDATA%\\Google\\Chrome\\User Data\\Default\\Cache",
                "BleachBit",
                "Chrome 缓存",
            ),
            (
                "edge",
                "%LOCALAPPDATA%\\Microsoft\\Edge\\User Data\\Default\\Cache",
                "BleachBit",
                "Edge 缓存",
            ),
            (
                "firefox",
                "%LOCALAPPDATA%\\Mozilla\\Firefox\\Profiles",
                "BleachBit",
                "Firefox 缓存",
            ),
        ]
    } else {
        vec![
            ("win_temp", "/tmp", "Windows", "系统临时文件"),
            ("user_cache", "~/.cache", "BleachBit", "用户缓存"),
        ]
    }
}

/// 逐文件统计体积，顺便把当前文件写进进度（前端拿它滚动显示）
pub(crate) fn walk_stat(dir: &Path, files: &mut u64, bytes: &mut u64, depth: usize) {
    if depth > 14 {
        return;
    }
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        // 必须用 symlink_metadata：Windows 上 e.metadata() 会跟随 junction，
        // Temp 目录里只要有一个指向 C:\ 的联接点，这次统计就变成全盘遍历，
        // 界面上 15 分钟也只显示「已扫 0 个文件」。
        let Ok(md) = fs::symlink_metadata(e.path()) else {
            continue;
        };
        if md.file_type().is_symlink() {
            continue;
        }
        if md.is_dir() {
            walk_stat(&e.path(), files, bytes, depth + 1);
        } else {
            *files += 1;
            *bytes += md.len();
            if *files % 40 == 0 {
                if let Ok(mut g) = CLEAN_CUR.lock() {
                    *g = e.path().to_string_lossy().to_string();
                }
                CLEAN_FILES.store(*files, Ordering::Relaxed);
                CLEAN_BYTES.store(*bytes, Ordering::Relaxed);
            }
        }
    }
}

/// 清理范围扫描：quick 内置垃圾目录 / full 全部固定盘的系统级垃圾 / custom 指定目录
#[no_mangle]
pub extern "C" fn cleanup_scan_mode(
    mode: *const c_char,
    path: *const c_char,
    buf: *mut u8,
    len: usize,
) -> i32 {
    crate::ffi_guard!(buf, len, {
        let Some(mode) = cstr(mode) else {
            return fail(buf, len, -1, "模式为空");
        };
        let extra = cstr(path).unwrap_or_default();

        CLEAN_RUNNING.store(true, Ordering::Relaxed);
        CLEAN_FILES.store(0, Ordering::Relaxed);
        CLEAN_BYTES.store(0, Ordering::Relaxed);
        if let Ok(mut g) = CLEAN_ITEMS.lock() {
            g.clear();
        }

        let mut items = Vec::new();
        let mut total = 0u64;

        // 1) 内置垃圾目录：多个目录并行统计（rayon 保证结果顺序不变）。
        // 以前 8 个目录一个接一个走，Temp 里几十万个小文件就卡在那儿；
        // 现在每个目录一个任务，按核心数同时跑。
        let scanned: Vec<(String, String, String, u64, String)> = rules()
            .into_par_iter()
            .filter_map(|(id, raw, source, category)| {
                let p = expand(raw)?;
                if !p.exists() {
                    return None;
                }
                if let Ok(mut g) = CLEAN_CUR.lock() {
                    *g = format!("定位 {}", category);
                }
                let (mut _f, mut b) = (0u64, 0u64);
                walk_stat(&p, &mut _f, &mut b, 0);
                if b == 0 {
                    return None;
                }
                Some((
                    id.to_string(),
                    category.to_string(),
                    p.to_string_lossy().to_string(),
                    b,
                    source.to_string(),
                ))
            })
            .collect();

        for (id, category, path, b, source) in scanned {
            total += b;
            if let Ok(mut g) = CLEAN_ITEMS.lock() {
                if g.len() < 40 {
                    g.push(serde_json::json!({
                        "id": &id, "category": &category, "path": &path, "size": b
                    }));
                }
            }
            items.push(CleanItem {
                id,
                category,
                path,
                size_bytes: b,
                default_checked: true,
                source,
            });
        }

        // 2) 全盘：各固定盘上的系统级垃圾
        if mode == "full" {
            for root in ext::drives("fixed") {
                for sub in [
                    "$Recycle.Bin",
                    "Windows\\Temp",
                    "Temp",
                    "Windows\\SoftwareDistribution\\Download",
                    "Windows\\Logs",
                    "Windows\\Prefetch",
                    "ProgramData\\Package Cache",
                ] {
                    let p = root.join(sub);
                    if !p.exists() {
                        continue;
                    }
                    let (mut f, mut b) = (0u64, 0u64);
                    walk_stat(&p, &mut f, &mut b, 0);
                    if b == 0 {
                        continue;
                    }
                    total += b;
                    items.push(CleanItem {
                        id: format!("full:{}", sub),
                        category: "系统级垃圾".into(),
                        path: p.to_string_lossy().into(),
                        size_bytes: b,
                        default_checked: !sub.contains("$Recycle.Bin"),
                        source: "全盘扫描".into(),
                    });
                }
            }
        }

        // 3) 指定目录
        if mode == "custom" {
            let p = PathBuf::from(&extra);
            if !p.exists() {
                CLEAN_RUNNING.store(false, Ordering::Relaxed);
                return fail(buf, len, -3, "路径不存在");
            }
            let (mut f, mut b) = (0u64, 0u64);
            walk_stat(&p, &mut f, &mut b, 0);
            if b > 0 {
                total += b;
                items.push(CleanItem {
                    id: "custom".into(),
                    category: "指定位置".into(),
                    path: p.to_string_lossy().into(),
                    size_bytes: b,
                    default_checked: true,
                    source: "指定位置".into(),
                });
            }
        }

        CLEAN_RUNNING.store(false, Ordering::Relaxed);
        ok(
            buf,
            len,
            "扫描完成",
            serde_json::json!({
                "total_bytes": total,
                "files": CLEAN_FILES.load(Ordering::Relaxed),
                "items": items,
                "scope": if mode == "full" { "全盘清理" } else if mode == "custom" { "指定位置清理" } else { "快速清理" },
            }),
        )
    })
}

static CLEAN_ITEMS: Mutex<Vec<serde_json::Value>> = Mutex::new(Vec::new());

#[no_mangle]
pub extern "C" fn cleanup_progress(buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        let cur = CLEAN_CUR.lock().map(|s| s.clone()).unwrap_or_default();
        ok(
            buf,
            len,
            "清理进度",
            serde_json::json!({
                "running": CLEAN_RUNNING.load(Ordering::Relaxed),
                "files": CLEAN_FILES.load(Ordering::Relaxed),
                "bytes": CLEAN_BYTES.load(Ordering::Relaxed),
                "current": cur,
                "items": CLEAN_ITEMS.lock().map(|s| s.clone()).unwrap_or_default(),
            }),
        )
    })
}

#[no_mangle]
pub extern "C" fn scan_cleanup(buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        let mut items = Vec::new();
        let mut total = 0u64;
        for (id, raw, source, category) in rules() {
            let Some(p) = expand(raw) else { continue };
            let size = dir_size(&p, 8);
            if size == 0 {
                continue;
            }
            total += size;
            items.push(CleanItem {
                id: id.into(),
                category: category.into(),
                path: p.to_string_lossy().into(),
                size_bytes: size,
                default_checked: true,
                source: source.into(),
            });
        }
        ok(
            buf,
            len,
            "扫描完成",
            serde_json::json!({"total_bytes": total, "items": items}),
        )
    })
}

#[derive(serde::Deserialize)]
struct CleanReq {
    paths: Vec<String>,
    #[serde(default)]
    dry_run: bool,
}

pub(crate) fn wipe(
    path: &Path,
    dry: bool,
    deleted: &mut u64,
    freed: &mut u64,
    failed: &mut Vec<String>,
) {
    let Ok(meta) = fs::symlink_metadata(path) else {
        failed.push(format!("{}: 不存在", path.display()));
        return;
    };
    if meta.file_type().is_symlink() || crate::util::is_reparse(&meta) {
        return;
    }
    if meta.is_file() {
        if dry || fs::remove_file(path).is_ok() {
            *deleted += 1;
            *freed += meta.len();
        } else {
            failed.push(format!("{}: 删除失败", path.display()));
        }
        return;
    }
    if let Ok(rd) = fs::read_dir(path) {
        for e in rd.flatten() {
            wipe(&e.path(), dry, deleted, freed, failed);
        }
    }
}

pub(crate) fn is_protected(p: &str) -> bool {
    crate::util::is_protected(Path::new(p))
}

#[no_mangle]
pub extern "C" fn execute_cleanup(req: *const c_char, buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        let Some(raw) = cstr(req) else {
            return fail(buf, len, -1, "请求为空");
        };
        let Ok(r) = serde_json::from_str::<CleanReq>(&raw) else {
            return fail(buf, len, -1, "请求解析失败");
        };
        if !r.dry_run {
            if let Err(e) = crate::security::require_admin("执行清理删除") {
                return fail(buf, len, -5, &e);
            }
        }

        let (mut deleted, mut freed, mut failed) = (0u64, 0u64, Vec::new());
        for p in &r.paths {
            if is_protected(p) {
                failed.push(format!("{}: 系统关键目录，已拒绝", p));
                continue;
            }
            wipe(
                Path::new(p),
                r.dry_run,
                &mut deleted,
                &mut freed,
                &mut failed,
            );
        }
        ok(
            buf,
            len,
            if r.dry_run {
                "预演完成（未删除）"
            } else {
                "清理完成"
            },
            serde_json::json!({
                "deleted_files": deleted,
                "freed_bytes": freed,
                "failed": failed,
                "dry_run": r.dry_run
            }),
        )
    })
}

// ============ 查杀 ============

fn find(paths: &[&str]) -> Option<String> {
    paths
        .iter()
        .find(|p| Path::new(p).exists())
        .map(|s| s.to_string())
}

/// 单引擎执行：返回（是否感染，威胁列表，原始输出）
pub(crate) fn run_engine(engine: &str, target: &str) -> Result<(bool, Vec<String>), String> {
    let output = match engine {
        "defender" => {
            let Some(exe) = find(&[
                "C:\\Program Files\\Windows Defender\\MpCmdRun.exe",
                "C:\\Program Files (x86)\\Windows Defender\\MpCmdRun.exe",
            ]) else {
                return Err("未找到 Windows Defender".into());
            };
            crate::proc::cmd(exe)
                .args(["-Scan", "-ScanType", "3", "-File", target])
                .output()
        }
        // YARA-X：纯 Rust、进程内扫描。规则在第一次调用时编译好并缓存，
        // 之后每个文件只是内存匹配，不再 CreateProcess。
        "yara" => return Ok(crate::engines::yara_scan(target)),
        "signature" => return Ok(crate::engines::signature_scan(target)),
        "heuristic" => return Ok(crate::engines::heuristic_scan(target)),
        _ => return Err("未知引擎".into()),
    };

    let out = output.map_err(|e| format!("引擎调用失败: {e}"))?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    let threats: Vec<String> = text
        .lines()
        .filter(|l| l.contains("FOUND") || l.contains("Detected"))
        .map(|l| l.trim().to_string())
        .collect();
    let infected = if engine == "defender" {
        text.contains("Threat") || text.contains("威胁")
    } else {
        !threats.is_empty()
    };
    Ok((infected, threats))
}

#[no_mangle]
pub extern "C" fn scan_file(
    engine: *const c_char,
    target: *const c_char,
    buf: *mut u8,
    len: usize,
) -> i32 {
    crate::ffi_guard!(buf, len, {
        let (Some(engine), Some(target)) = (cstr(engine), cstr(target)) else {
            return fail(buf, len, -1, "参数为空");
        };
        if ext::is_whitelisted(&target) {
            return ok(
                buf,
                len,
                "已跳过（白名单）",
                serde_json::json!({
                    "engine": engine, "target": target, "infected": false, "skipped": true
                }),
            );
        }
        if !Path::new(&target).exists() {
            return fail(buf, len, -3, "目标路径不存在");
        }

        match run_engine(&engine, &target) {
            Ok((infected, threats)) => ok(
                buf,
                len,
                "扫描完成",
                serde_json::json!({
                    "engine": engine, "target": target, "infected": infected, "threats": threats
                }),
            ),
            Err(e) => fail(buf, len, -3, &e),
        }
    })
}

#[no_mangle]
pub extern "C" fn launch_external(name: *const c_char, buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        let Some(name) = cstr(name) else {
            return fail(buf, len, -1, "参数为空");
        };
        let candidates: &[&str] = match name.as_str() {
            "huorong" => &[
                "C:\\Program Files\\Huorong\\Sysdiag\\bin\\hrscan.exe",
                "C:\\Program Files (x86)\\Huorong\\Sysdiag\\bin\\hrscan.exe",
            ],
            "pyas" => &[
                "C:\\Program Files\\PYAS\\PYAS.exe",
                "C:\\Program Files (x86)\\PYAS\\PYAS.exe",
            ],
            _ => return fail(buf, len, -1, "未知工具"),
        };
        let Some(exe) = find(candidates) else {
            return fail(buf, len, -3, "本机未安装该工具");
        };
        match crate::proc::cmd(&exe).spawn() {
            Ok(_) => ok(buf, len, "已启动", serde_json::json!({"exe": exe})),
            Err(e) => fail(buf, len, -3, &format!("启动失败: {e}")),
        }
    })
}

// ============ 后台任务辅助（security.rs 调用） ============

/// 后台日志：追加写入 cfg_dir()/bg.log，界面可以读出来给人看
pub(crate) fn bg_log(line: &str) {
    use std::io::Write as _;
    let dir = ext::cfg_dir();
    let _ = fs::create_dir_all(&dir);
    if let Ok(mut f) = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("bg.log"))
    {
        let _ = writeln!(f, "{line}");
    }
}

/// 后台静默清理：按内置规则扫一遍并真删，返回（释放字节，删除文件数）
pub(crate) fn clean_all_quiet() -> (u64, u64) {
    let (mut deleted, mut freed, mut failed) = (0u64, 0u64, Vec::new());
    for (_, raw, _, _) in rules() {
        let Some(p) = expand(raw) else { continue };
        let s = p.to_string_lossy().to_string();
        if is_protected(&s) {
            continue;
        }
        wipe(&p, false, &mut deleted, &mut freed, &mut failed);
    }
    (freed, deleted)
}

/// 后台静默查杀：扫几个高风险目录，命中直接进隔离库（不删，可恢复）
pub(crate) fn scan_common_dirs_quiet(auto_quarantine: bool) -> u64 {
    let mut found = 0u64;
    let mut dirs: Vec<PathBuf> = Vec::new();
    for raw in [
        "%TEMP%",
        "%USERPROFILE%\\Downloads",
        "%USERPROFILE%\\Desktop",
        "~/.cache",
        "~/Downloads",
    ] {
        if let Some(p) = expand(raw) {
            dirs.push(p);
        }
    }

    for d in dirs {
        let mut files = Vec::new();
        ext::walk(&d, &mut files, 3);
        files.truncate(300);
        for f in files {
            let s = f.to_string_lossy().to_string();
            if ext::is_whitelisted(&s) {
                continue;
            }
            if let Ok((infected, _)) = run_engine("defender", &s) {
                if infected {
                    found += 1;
                    // 严格模式开启时，后台不能替用户把文件关进隔离库；
                    // 只记录命中，等用户回到界面亲自处理。
                    if auto_quarantine {
                        let _ = quarantine::add_internal(&s, "defender", "后台扫描命中");
                    }
                }
            }
        }
    }
    found
}

// ================= 规则库（疫苗库）维护接口 =================

/// 规则库状态：哈希条数、文件名条数、内置 YARA 是否存在
#[no_mangle]
pub extern "C" fn rules_status(buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        let st = crate::engines::rules_status();
        ok(buf, len, "规则库状态", st)
    })
}

/// 从本地 txt 导入 SHA-256 黑名单（参数：文件路径）
#[no_mangle]
pub extern "C" fn rules_import(src: *const c_char, buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        let Some(src) = cstr(src) else {
            return fail(buf, len, -1, "参数为空");
        };
        match crate::engines::import_hashes(&src) {
            Ok((p, a, t)) => ok(
                buf,
                len,
                "导入完成",
                serde_json::json!({ "parsed": p, "added": a, "total": t }),
            ),
            Err(e) => fail(buf, len, -3, &e),
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_panic_is_caught() {
        let mut buf = [0u8; 256];
        let r = crate::ffi_guard!(buf.as_mut_ptr(), buf.len(), { panic!("boom") });
        assert_eq!(r, -4, "panic 必须被拦成 -4，而不是 abort");
        let text = unsafe { CStr::from_ptr(buf.as_ptr() as *const c_char) }
            .to_string_lossy()
            .to_string();
        assert!(text.contains("内部错误"));
    }
}
