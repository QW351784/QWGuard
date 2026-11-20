//! QW 电脑安全管家 —— Rust 底层（FFI 导出）
//!
//! 统一约定：
//! - 结果为 UTF-8 JSON，写入调用方缓冲区，末尾补 '\0'
//! - 返回：0 成功 / -1 参数错 / -2 缓冲区不足 / -3 执行失败

use serde::Serialize;
use serde_json::Value;
use std::ffi::{c_char, CStr};
use std::fs;
use std::path::{Path, PathBuf};

mod ext;
mod installer;
mod quarantine;
mod runtime;
mod security;
mod tools;
#[cfg(windows)]
mod topmost;

pub(crate) fn respond(buf: *mut u8, len: usize, ok: bool, code: i32, msg: &str, data: Value) -> i32 {
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
    respond(buf, len, true, 0, msg, serde_json::to_value(data).unwrap_or(Value::Null))
}

pub(crate) fn fail(buf: *mut u8, len: usize, code: i32, msg: &str) -> i32 {
    respond(buf, len, false, code, msg, Value::Null);
    code
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
        let Some(rel) = s[start + 1..].find('%') else { break };
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
        let home = std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE")).ok()?;
        s = format!("{}/{}", home, rest);
    }
    let p = PathBuf::from(s);
    p.exists().then_some(p)
}

pub(crate) fn dir_size(path: &Path, depth: usize) -> u64 {
    if depth == 0 {
        return 0;
    }
    let Ok(meta) = fs::symlink_metadata(path) else { return 0 };
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

// ============ 自检 ============

#[no_mangle]
pub extern "C" fn ping() -> i32 {
    20261120
}

// ============ 硬件 ============

#[derive(Serialize)]
struct Disk {
    name: String,
    total_gb: f32,
    free_gb: f32,
    #[serde(skip_serializing_if = "Option::is_none")]
    media: Option<String>,
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
    use sysinfo::{Components, Disks, System};

    let mut sys = System::new_all();
    sys.refresh_all();

    let mut cpu_name = String::new();
    if let Some(c) = sys.cpus().first() {
        cpu_name = c.brand().trim().to_string();
    }
    let cores = sys.cpus().len();
    let load = round1(sys.global_cpu_info().cpu_usage());

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

    let (mut cpu_temp, mut gpu_temp, mut disk_temp) = (None, None, None);
    for c in Components::new_with_refreshed_list().list() {
        let l = c.label().to_lowercase();
        let t = round1(c.temperature());
        if cpu_temp.is_none() && (l.contains("cpu") || l.contains("core")) {
            cpu_temp = Some(t);
        } else if gpu_temp.is_none() && (l.contains("gpu") || l.contains("nvidia") || l.contains("radeon")) {
            gpu_temp = Some(t);
        } else if disk_temp.is_none() && (l.contains("nvme") || l.contains("ssd") || l.contains("hdd")) {
            disk_temp = Some(t);
        }
    }

    let gpus = ext::detect_gpus();
    let recommended = ext::recommend_gpu(&gpus);

    ok(buf, len, "硬件信息读取完成", Hardware {
        cpu_name,
        cpu_cores: cores,
        cpu_load: load,
        mem_total_gb: round1(sys.total_memory() as f32 / 1073741824.0),
        mem_used_gb: round1(sys.used_memory() as f32 / 1073741824.0),
        cpu_temp,
        gpu_temp,
        disk_temp,
        disks,
        gpus,
        recommended_gpu: recommended,
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
            ("local_temp", "%LOCALAPPDATA%\\Temp", "Windows", "系统临时文件"),
            ("prefetch", "C:\\Windows\\Prefetch", "Windows", "系统预读缓存"),
            ("wer", "C:\\ProgramData\\Microsoft\\Windows\\WER", "Windows", "错误报告"),
            ("thumb", "%LOCALAPPDATA%\\Microsoft\\Windows\\Explorer", "Windows", "缩略图缓存"),
            ("chrome", "%LOCALAPPDATA%\\Google\\Chrome\\User Data\\Default\\Cache", "BleachBit", "Chrome 缓存"),
            ("edge", "%LOCALAPPDATA%\\Microsoft\\Edge\\User Data\\Default\\Cache", "BleachBit", "Edge 缓存"),
            ("firefox", "%LOCALAPPDATA%\\Mozilla\\Firefox\\Profiles", "BleachBit", "Firefox 缓存"),
        ]
    } else {
        vec![
            ("win_temp", "/tmp", "Windows", "系统临时文件"),
            ("user_cache", "~/.cache", "BleachBit", "用户缓存"),
        ]
    }
}

#[no_mangle]
pub extern "C" fn scan_cleanup(buf: *mut u8, len: usize) -> i32 {
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
    ok(buf, len, "扫描完成", serde_json::json!({"total_bytes": total, "items": items}))
}

#[derive(serde::Deserialize)]
struct CleanReq {
    paths: Vec<String>,
    #[serde(default)]
    dry_run: bool,
}

pub(crate) fn wipe(path: &Path, dry: bool, deleted: &mut u64, freed: &mut u64, failed: &mut Vec<String>) {
    let Ok(meta) = fs::symlink_metadata(path) else {
        failed.push(format!("{}: 不存在", path.display()));
        return;
    };
    if meta.file_type().is_symlink() {
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
    let t = p.trim_end_matches(['\\', '/']).to_lowercase();
    matches!(t.as_str(), "c:" | "c:\\windows" | "/" | "/etc" | "/usr" | "/bin" | "/home")
}

#[no_mangle]
pub extern "C" fn execute_cleanup(req: *const c_char, buf: *mut u8, len: usize) -> i32 {
    let Some(raw) = cstr(req) else { return fail(buf, len, -1, "请求为空") };
    let Ok(r) = serde_json::from_str::<CleanReq>(&raw) else { return fail(buf, len, -1, "请求解析失败") };

    let (mut deleted, mut freed, mut failed) = (0u64, 0u64, Vec::new());
    for p in &r.paths {
        if is_protected(p) {
            failed.push(format!("{}: 系统关键目录，已拒绝", p));
            continue;
        }
        wipe(Path::new(p), r.dry_run, &mut deleted, &mut freed, &mut failed);
    }
    ok(buf, len, if r.dry_run { "预演完成（未删除）" } else { "清理完成" },
       serde_json::json!({
           "deleted_files": deleted,
           "freed_bytes": freed,
           "failed": failed,
           "dry_run": r.dry_run
       }))
}

// ============ 查杀 ============

fn find(paths: &[&str]) -> Option<String> {
    paths.iter().find(|p| Path::new(p).exists()).map(|s| s.to_string())
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
            std::process::Command::new(exe)
                .args(["-Scan", "-ScanType", "3", "-File", target])
                .output()
        }
        "clamav" => {
            let Some(exe) = find(&["clamscan.exe", "C:\\Program Files\\ClamAV\\clamscan.exe", "/usr/bin/clamscan"]) else {
                return Err("未找到 ClamAV".into());
            };
            std::process::Command::new(exe).args(["--no-summary", target]).output()
        }
        "yara" => {
            let Some(exe) = find(&["yara-x.exe", "yara.exe", "yr"]) else {
                return Err("未找到 YARA".into());
            };
            let rules = std::env::var("TOOLBOX_YARA_RULES").unwrap_or_else(|_| "rules.yar".into());
            std::process::Command::new(exe).args([&rules, target]).output()
        }
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
pub extern "C" fn scan_file(engine: *const c_char, target: *const c_char, buf: *mut u8, len: usize) -> i32 {
    let (Some(engine), Some(target)) = (cstr(engine), cstr(target)) else {
        return fail(buf, len, -1, "参数为空");
    };
    if ext::is_whitelisted(&target) {
        return ok(buf, len, "已跳过（白名单）", serde_json::json!({
            "engine": engine, "target": target, "infected": false, "skipped": true
        }));
    }
    if !Path::new(&target).exists() {
        return fail(buf, len, -3, "目标路径不存在");
    }

    match run_engine(&engine, &target) {
        Ok((infected, threats)) => ok(buf, len, "扫描完成", serde_json::json!({
            "engine": engine, "target": target, "infected": infected, "threats": threats
        })),
        Err(e) => fail(buf, len, -3, &e),
    }
}

#[no_mangle]
pub extern "C" fn launch_external(name: *const c_char, buf: *mut u8, len: usize) -> i32 {
    let Some(name) = cstr(name) else { return fail(buf, len, -1, "参数为空") };
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
    let Some(exe) = find(candidates) else { return fail(buf, len, -3, "本机未安装该工具") };
    match std::process::Command::new(&exe).spawn() {
        Ok(_) => ok(buf, len, "已启动", serde_json::json!({"exe": exe})),
        Err(e) => fail(buf, len, -3, &format!("启动失败: {e}")),
    }
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
pub(crate) fn scan_common_dirs_quiet() -> u64 {
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
                    let _ = quarantine::add_internal(&s, "defender", "后台扫描命中");
                }
            }
        }
    }
    found
}
