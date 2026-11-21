//! QW 安全电脑管家 —— 扩展能力：显卡判定、设置、自启动、U盘、安装目录、运行库、更新、白名单、多线程扫描

use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::ffi::c_char;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::{cstr, fail, ok, round1};

// ================= 显卡 =================

#[derive(Serialize, Clone)]
pub struct Gpu {
    pub name: String,
    pub kind: String,       // discrete / integrated
    pub vendor: String,     // nvidia / amd / intel / other
    pub vram_mb: u32,
    pub score: u32,
    pub note: String,
}

fn classify(name: &str) -> &'static str {
    let n = name.to_lowercase();
    const DISCRETE: [&str; 12] = [
        "nvidia", "geforce", "rtx", "gtx", "quadro", "radeon rx", "rx 5", "rx 6", "rx 7",
        "arc a", "arc b", "intel arc",
    ];
    const INTEGRATED: [&str; 8] = [
        "intel uhd", "intel iris", "hd graphics", "uhd graphics", "radeon graphics",
        "vega", "apple m", "microsoft basic",
    ];
    if INTEGRATED.iter().any(|k| n.contains(k)) {
        "integrated"
    } else if DISCRETE.iter().any(|k| n.contains(k)) {
        "discrete"
    } else {
        "integrated"
    }
}

fn vendor_of(name: &str) -> &'static str {
    let n = name.to_lowercase();
    if n.contains("nvidia") || n.contains("geforce") || n.contains("rtx") || n.contains("gtx") || n.contains("quadro") {
        "nvidia"
    } else if n.contains("amd") || n.contains("radeon") || n.contains("rx ") {
        "amd"
    } else if n.contains("intel") || n.contains("iris") || n.contains("uhd") || n.contains("arc") {
        "intel"
    } else {
        "other"
    }
}

fn score_of(name: &str, kind: &str, vram_mb: u32) -> u32 {
    let n = name.to_lowercase();
    if kind == "integrated" {
        return 50 + (vram_mb / 512).min(4);
    }
    let mut base = 80 + (vram_mb / 1024) * 5;
    for (k, add) in [
        ("rtx 50", 40), ("rtx 40", 30), ("rtx 30", 20), ("rtx 20", 12),
        ("gtx 16", 8), ("gtx 10", 4), ("rx 9", 32), ("rx 7", 22), ("rx 6", 14), ("arc b", 18),
    ] {
        if n.contains(k) {
            base += add;
            break;
        }
    }
    base.min(200)
}

pub fn detect_gpus() -> Vec<Gpu> {
    let mut out = Vec::new();

    if cfg!(windows) {
        let script = "Get-CimInstance Win32_VideoController | Select-Object Name,AdapterRAM | ConvertTo-Json -Compress";
        if let Ok(o) = Command::new("powershell").args(["-NoProfile", "-Command", script]).output() {
            let text = String::from_utf8_lossy(&o.stdout).to_string();
            if let Ok(v) = serde_json::from_str::<Value>(&text) {
                let list = match v {
                    Value::Array(a) => a,
                    other => vec![other],
                };
                for item in list {
                    let name = item.get("Name").and_then(|x| x.as_str()).unwrap_or("").trim().to_string();
                    if name.is_empty() {
                        continue;
                    }
                    let vram = item.get("AdapterRAM").and_then(|x| x.as_u64()).unwrap_or(0) as u32 / 1048576;
                    push_gpu(&mut out, name, vram);
                }
            }
        }
    }

    if out.is_empty() {
        // Linux / 兜底
        if let Ok(o) = Command::new("sh").args(["-c", "lspci 2>/dev/null | grep -Ei 'vga|3d|display'"]).output() {
            for line in String::from_utf8_lossy(&o.stdout).lines() {
                let name = line.split(": ").last().unwrap_or(line).trim().to_string();
                if !name.is_empty() {
                    push_gpu(&mut out, name, 0);
                }
            }
        }
    }

    out
}

fn push_gpu(out: &mut Vec<Gpu>, name: String, vram: u32) {
    let kind = classify(&name).to_string();
    let score = score_of(&name, &kind, vram);
    let note = if kind == "discrete" {
        "独立显卡".to_string()
    } else {
        "核显 / 集显".to_string()
    };
    if out.iter().any(|g| g.name == name) {
        return;
    }
    let vendor = vendor_of(&name).to_string();
    out.push(Gpu { name, kind, vendor, vram_mb: vram, score, note });
}

pub fn recommend_gpu(gpus: &[Gpu]) -> String {
    if gpus.is_empty() {
        return "none".into();
    }
    let mut best = &gpus[0];
    for g in gpus {
        if g.score > best.score {
            best = g;
        }
    }
    best.kind.clone()
}

#[no_mangle]
pub extern "C" fn detect_gpu(buf: *mut u8, len: usize) -> i32 {
    let gpus = detect_gpus();
    let recommended = recommend_gpu(&gpus);
    ok(buf, len, "显卡检测完成", json!({"gpus": gpus, "recommended": recommended}))
}

#[no_mangle]
pub extern "C" fn get_gpu_preference(buf: *mut u8, len: usize) -> i32 {
    let cfg = load_config();
    let mode = cfg.get("gpu_mode").and_then(|v| v.as_str()).unwrap_or("auto");
    let gpus = detect_gpus();
    let detected = recommend_gpu(&gpus);
    let effective = match mode {
        "discrete" => "discrete",
        "integrated" => "integrated",
        _ => detected.as_str(),
    };
    ok(buf, len, "显卡偏好", json!({
        "mode": mode,
        "detected": detected,
        "effective": effective,
        "gpus": gpus
    }))
}

// ================= 配置 =================

pub(crate) fn cfg_dir() -> PathBuf {
    if cfg!(windows) {
        let base = std::env::var("APPDATA").unwrap_or_else(|_| ".".into());
        PathBuf::from(base).join("QWGuard")
    } else {
        std::env::var("HOME")
            .map(|h| PathBuf::from(h).join(".config/qwguard"))
            .unwrap_or_else(|_| PathBuf::from("/tmp/qwguard"))
    }
}

fn cfg_path() -> PathBuf {
    cfg_dir().join("config.json")
}

pub(crate) fn load_config() -> Value {
    fs::read_to_string(cfg_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_else(|| json!({}))
}

pub(crate) fn save_config(v: &Value) {
    let dir = cfg_dir();
    let _ = fs::create_dir_all(&dir);
    let _ = fs::write(cfg_path(), v.to_string());
}

#[no_mangle]
pub extern "C" fn get_settings(buf: *mut u8, len: usize) -> i32 {
    ok(buf, len, "设置", load_config())
}

#[no_mangle]
pub extern "C" fn set_setting(key: *const c_char, value: *const c_char, buf: *mut u8, len: usize) -> i32 {
    let (Some(k), Some(v)) = (cstr(key), cstr(value)) else {
        return fail(buf, len, -1, "参数为空");
    };
    let mut cfg = load_config();
    if let Value::Object(ref mut map) = cfg {
        let parsed = serde_json::from_str::<Value>(&v).unwrap_or(Value::String(v.clone()));
        map.insert(k.clone(), parsed);
    }
    save_config(&cfg);
    ok(buf, len, "已保存", json!({"key": k, "value": v}))
}

// ================= 开机自启动 =================

#[derive(Serialize, Deserialize, Clone)]
struct AutoItem {
    name: String,
    cmd: String,
    enabled: bool,
}

#[no_mangle]
pub extern "C" fn autostart_list(buf: *mut u8, len: usize) -> i32 {
    let mut items = Vec::new();
    if cfg!(windows) {
        if let Ok(o) = Command::new("reg")
            .args(["query", r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run"])
            .output()
        {
            for line in String::from_utf8_lossy(&o.stdout).lines() {
                let t = line.trim();
                if let Some((k, v)) = t.split_once("    REG_SZ    ") {
                    items.push(AutoItem { name: k.trim().to_string(), cmd: v.trim().to_string(), enabled: true });
                }
            }
        }
    } else {
        let dir = std::env::var("HOME").unwrap_or_default() + "/.config/autostart";
        if let Ok(rd) = fs::read_dir(&dir) {
            for e in rd.flatten() {
                let p = e.path();
                if p.extension().map(|x| x == "desktop").unwrap_or(false) {
                    let text = fs::read_to_string(&p).unwrap_or_default();
                    let exec = text.lines().find(|l| l.starts_with("Exec=")).unwrap_or("Exec=").to_string();
                    items.push(AutoItem {
                        name: p.file_stem().unwrap_or_default().to_string_lossy().into(),
                        cmd: exec.trim_start_matches("Exec=").to_string(),
                        enabled: true,
                    });
                }
            }
        }
    }
    ok(buf, len, "自启动列表", json!({"items": items}))
}

#[no_mangle]
pub extern "C" fn autostart_set(name: *const c_char, exe: *const c_char, enabled: i32, buf: *mut u8, len: usize) -> i32 {
    let (Some(name), Some(exe)) = (cstr(name), cstr(exe)) else {
        return fail(buf, len, -1, "参数为空");
    };
    if cfg!(windows) {
        let run = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
        let res = if enabled != 0 {
            Command::new("reg")
                .args(["add", run, "/v", &name, "/t", "REG_SZ", "/d", &exe, "/f"])
                .output()
        } else {
            Command::new("reg").args(["delete", run, "/v", &name, "/f"]).output()
        };
        match res {
            Ok(o) if o.status.success() => ok(buf, len, "已更新自启动", json!({"name": name, "enabled": enabled != 0})),
            _ => fail(buf, len, -3, "注册表操作失败（可能需要权限）"),
        }
    } else {
        let path = PathBuf::from(std::env::var("HOME").unwrap_or_default())
            .join(".config/autostart")
            .join(format!("{name}.desktop"));
        if enabled != 0 {
            let _ = fs::create_dir_all(path.parent().unwrap());
            let content = format!("[Desktop Entry]\nType=Application\nName={name}\nExec={exe}\nX-GNOME-Autostart-enabled=true\n");
            match fs::write(&path, content) {
                Ok(_) => ok(buf, len, "已开启自启动", json!({"name": name, "path": path.to_string_lossy()})),
                Err(e) => fail(buf, len, -3, &format!("写入失败: {e}")),
            }
        } else {
            let _ = fs::remove_file(&path);
            ok(buf, len, "已关闭自启动", json!({"name": name}))
        }
    }
}

// ================= U 盘检测 =================

#[derive(Serialize)]
struct UsbDrive {
    letter: String,
    label: String,
    size_gb: f32,
    filesystem: String,
    autorun: bool,
    risk: bool,
}

#[no_mangle]
pub extern "C" fn usb_check(buf: *mut u8, len: usize) -> i32 {
    let mut drives = Vec::new();

    if cfg!(windows) {
        let script = "Get-Volume | Where-Object {$_.DriveType -eq 'Removable'} | Select-Object DriveLetter,FileSystemLabel,Size,FileSystem | ConvertTo-Json -Compress";
        if let Ok(o) = Command::new("powershell").args(["-NoProfile", "-Command", script]).output() {
            if let Ok(v) = serde_json::from_str::<Value>(&String::from_utf8_lossy(&o.stdout)) {
                let list = match v { Value::Array(a) => a, other => vec![other] };
                for item in list {
                    let letter = item.get("DriveLetter").and_then(|x| x.as_str()).unwrap_or("").to_string();
                    if letter.is_empty() {
                        continue;
                    }
                    let autorun = Path::new(&format!("{letter}:\\autorun.inf")).exists();
                    let size_gb = item.get("Size").and_then(|x| x.as_f64()).unwrap_or(0.0) as f32 / 1073741824.0;
                    drives.push(UsbDrive {
                        letter: format!("{letter}:"),
                        label: item.get("FileSystemLabel").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                        size_gb: round1(size_gb),
                        filesystem: item.get("FileSystem").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                        autorun,
                        risk: autorun,
                    });
                }
            }
        }
    } else {
        if let Ok(text) = fs::read_to_string("/proc/mounts") {
            for line in text.lines() {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() < 2 {
                    continue;
                }
                let mp = parts[1];
                if mp.starts_with("/media") || mp.starts_with("/run/media") {
                    let autorun = Path::new(mp).join("autorun.inf").exists();
                    drives.push(UsbDrive {
                        letter: mp.to_string(),
                        label: mp.rsplit('/').next().unwrap_or("").to_string(),
                        size_gb: 0.0,
                        filesystem: parts[2].to_string(),
                        autorun,
                        risk: autorun,
                    });
                }
            }
        }
    }

    let risky = drives.iter().filter(|d| d.risk).count();
    ok(buf, len, "U 盘检测完成", json!({"drives": drives, "risky_count": risky}))
}

// ================= 安装目录推荐 =================

// NVMe 型号分档表（只按厂商定位粗分，拿不到真实读写速度）
// 0 档 = 旗舰 / 高性能，1 档 = 主流，其余 NVMe 记 2 档
const NVME_T0: &[&str] = &[
    // 三星
    "9100 PRO", "990 PRO", "980 PRO", "PM9A3", "PM1743",
    // 西数 / 闪迪
    "SN8100", "SN850X", "SN850", "SN8050",
    // 致态（长江存储）
    "TIPRO",
    // 铠侠 / 东芝
    "EXCERIA PRO", "XG8", "XG7",
    // Solidigm / SK 海力士
    "P44 PRO", "P41", "PC801", "PC811",
    // 美光 / 英睿达
    "T700", "T705",
    // 金士顿
    "KC3000", "FURY RENEGADE",
    // 威刚
    "S70", "LEGEND 960",
    // 浦科特
    "M10P",
    // 海盗船
    "MP600", "MP700",
    // 雷克沙
    "NM800",
    // 希捷
    "FIRECUDA 530", "酷玩 530",
    // 微星
    "SPATIUM M480", "M480",
    // 影驰
    "HOF", "名人堂",
    // HP
    "FX900",
    // 联想 / OEM 高端
    "SL700",
    // 海康存储 / 大华
    "C4000", "C970",
];

const NVME_T1: &[&str] = &[
    // 三星
    "PM9A1", "PM9B1", "980", "970 EVO", "970 PRO", "960 EVO", "SM961",
    // 西数 / 闪迪
    "SN770", "SN750", "SN740", "SN730", "SN570", "SN560", "SN550", "SN520",
    // 致态
    "TIPLUS 7100", "TIPLUS 5000", "TIPLUS 600", "TI600", "PC005",
    // 铠侠
    "EXCERIA PLUS", "EXCERIA G2", "BG5", "BG4", "RC10", "RC20",
    // Solidigm / 海力士
    "P41 PLUS", "P31", "P11",
    // 美光 / 英睿达
    "P5 PLUS", "P3 PLUS", "P3", "P2",
    // 金士顿
    "KC2500", "KC2000", "NV2", "NV1", "A2000", "FURY",
    // 威刚
    "S50", "S40", "LEGEND 850", "LEGEND 800",
    // 浦科特
    "M9P PLUS", "M9PEG", "M8PE", "M8SE",
    // 海盗船
    "MP500", "MP510",
    // 雷克沙
    "NM790", "NM620", "NM610",
    // 希捷
    "酷玩 520", "酷玩 510", "FIRECUDA 520",
    // 联想
    "SL7000", "SL500",
    // 海康存储 / 大华
    "CC700", "C3000", "C900", "C900 PLUS",
    // 铭瑄 / 七彩虹 / 台电 / 光威 / 金百达 / 梵想 / 铨兴 / 爱国者 / 长城
    "终结者", "太极", "CN700", "CN600", "CN500", "幻影", "弈", "天策", "骁将",
    "KP260", "KP200", "KP230", "S790", "S500 PRO", "S500", "S101", "猎鹰", "铨兴",
    "P7000", "P2000", "GT70", "GT50",
    // 影驰
    "星曜", "擎",
    // 微星
    "M470", "M390", "M370",
    // HP
    "EX900", "EX950",
    // 技嘉 / 华硕 / 戴尔 OEM
    "AORUS", "ROG", "SN530",
];

fn nvme_perf_score(model: &str) -> u8 {
    let m = model.to_uppercase();
    if NVME_T0.iter().any(|k| m.contains(&k.to_uppercase())) {
        0
    } else if NVME_T1.iter().any(|k| m.contains(&k.to_uppercase())) {
        1
    } else {
        2
    }
}

#[no_mangle]
pub extern "C" fn recommend_install_dir(buf: *mut u8, len: usize) -> i32 {
    // (路径, 剩余GB, 介质, 型号)
    let mut cands: Vec<(String, f32, String, String)> = Vec::new();

    if cfg!(windows) {
        let script = r#"Get-Volume | Where-Object {$_.DriveLetter} | ForEach-Object { $v=$_; try { $p=Get-Partition -DriveLetter $v.DriveLetter; $d=Get-PhysicalDisk -DeviceNumber $p.DiskNumber; [pscustomobject]@{Letter=$v.DriveLetter;Free=[double]$v.SizeRemaining;Media=[string]$d.MediaType;Bus=[string]$d.BusType;Model=[string]$d.FriendlyName} } catch {} } | ConvertTo-Json -Compress"#;
        if let Ok(o) = Command::new("powershell").args(["-NoProfile", "-Command", script]).output() {
            if let Ok(v) = serde_json::from_str::<Value>(&String::from_utf8_lossy(&o.stdout)) {
                let list = match v { Value::Array(a) => a, other => vec![other] };
                for item in list {
                    let letter = item.get("Letter").and_then(|x| x.as_str()).unwrap_or("");
                    if letter.is_empty() {
                        continue;
                    }
                    let free = item.get("Free").and_then(|x| x.as_f64()).unwrap_or(0.0) / 1073741824.0;
                    let media = item.get("Media").and_then(|x| x.as_str()).unwrap_or("").to_string();
                    let bus = item.get("Bus").and_then(|x| x.as_str()).unwrap_or("");
                    // MediaType 只区分 SSD/HDD，NVMe 要靠 BusType 补上
                    let media = if bus.to_uppercase().contains("NVME")
                        && !media.to_uppercase().contains("NVME")
                    {
                        format!("{media}/NVMe")
                    } else {
                        media
                    };
                    let model = item
                        .get("Model")
                        .and_then(|x| x.as_str())
                        .unwrap_or("")
                        .to_string();
                    cands.push((format!("{letter}:\\"), free as f32, media, model));
                }
            }
        }
    }

    if cands.is_empty() {
        // 兜底：用 sysinfo 磁盘
        use sysinfo::Disks;
        for d in Disks::new_with_refreshed_list().list() {
            let mp = d.mount_point().to_string_lossy().to_string();
            let is_dir = Path::new(&mp).is_dir();
            let skip = ["/proc", "/sys", "/dev", "/etc", "/run", "/boot", "/var/lib"]
                .iter()
                .any(|p| mp == *p || mp.starts_with(&format!("{p}/")));
            if !is_dir || skip {
                continue;
            }
            if !cfg!(windows) && mp != "/" && !mp.starts_with("/home") {
                continue;
            }
            let free = d.available_space() as f32 / 1073741824.0;
            let media = disk_media(&mp).unwrap_or_else(|| "Unknown".into());
            let model = d.name().to_string_lossy().to_string();
            cands.push((mp, free, media, model));
        }
    }

    let system_drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".into()).to_uppercase();

    // 分四步挑：① NVMe 固态优先 ② 其他固态 ③ 机械盘
    // 同档里再按型号粗分性能（旗舰型号排前面），最后非系统盘、剩余空间大的优先
    let rank = |c: &(String, f32, String, String)| -> (u8, u8, u8, f32) {
        let m = c.2.to_uppercase();
        let tier = if m.contains("NVME") {
            0u8
        } else if m.contains("SSD") {
            1
        } else {
            2
        };
        // 型号只能粗判：旗舰 0，主流 1，其余 2（拿不到真实读写速度）
        let perf = if tier == 0 {
            nvme_perf_score(&c.3)
        } else {
            2
        };
        let is_sys =
            c.0.to_uppercase().starts_with(&system_drive) || c.0.to_uppercase().starts_with("C:");
        (tier, perf, if is_sys { 1 } else { 0 }, c.1)
    };

    cands.sort_by(|a, b| {
        let ra = rank(a);
        let rb = rank(b);
        ra.0.cmp(&rb.0)
            .then(ra.1.cmp(&rb.1))
            .then(ra.2.cmp(&rb.2))
            .then(rb.3.partial_cmp(&ra.3).unwrap_or(std::cmp::Ordering::Equal))
    });

    let best = cands.first();

    match best {
        Some(b) => {
            let reason = format!(
                "{}（{} {}，剩余 {:.1} GB{}）",
                b.0,
                if b.2.is_empty() { "磁盘" } else { b.2.as_str() },
                b.3,
                b.1,
                if b.0.to_uppercase().starts_with("C:") { "，系统盘" } else { "" }
            );
            ok(buf, len, "推荐安装位置", json!({"path": b.0, "reason": reason, "candidates": cands.iter().map(|c| json!({"path": c.0, "free_gb": round1(c.1), "media": c.2, "model": c.3})).collect::<Vec<_>>() }))
        }
        None => fail(buf, len, -3, "未找到可用磁盘"),
    }
}

pub fn disk_media(mount: &str) -> Option<String> {
    if cfg!(windows) {
        None
    } else {
        let name = mount.trim_start_matches('/').split('/').next().unwrap_or("");
        let path = format!("/sys/block/{name}/queue/rotational");
        fs::read_to_string(path).ok().map(|s| {
            if s.trim() == "0" { "SSD".to_string() } else { "HDD".to_string() }
        })
    }
}

// ================= 运行库检查 =================

#[no_mangle]
pub extern "C" fn runtime_check(buf: *mut u8, len: usize) -> i32 {
    if !cfg!(windows) {
        return ok(buf, len, "非 Windows，跳过", json!({"ok": true, "missing": []}));
    }
    let needed = ["msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"];
    let mut missing = Vec::new();
    for dll in needed {
        if !Path::new("C:\\Windows\\System32").join(dll).exists() {
            missing.push(dll);
        }
    }
    ok(buf, len, "运行库检查", json!({"ok": missing.is_empty(), "missing": missing}))
}

// ================= GitHub 检查更新 =================

fn vtuple(s: &str) -> Vec<u32> {
    s.trim_start_matches('v')
        .split('.')
        .map(|p| p.chars().take_while(|c| c.is_ascii_digit()).collect::<String>())
        .map(|p| p.parse::<u32>().unwrap_or(0))
        .collect()
}

fn newer(latest: &str, current: &str) -> bool {
    let (a, b) = (vtuple(latest), vtuple(current));
    for i in 0..a.len().max(b.len()) {
        let x = a.get(i).copied().unwrap_or(0);
        let y = b.get(i).copied().unwrap_or(0);
        if x != y {
            return x > y;
        }
    }
    false
}

/// 统一 HTTP GET → JSON
#[cfg(not(windows))]
fn http_json(url: &str, token: &str) -> Result<Value, String> {
    let mut req = ureq::get(url)
        .set("User-Agent", "QWGuard")
        .set("Accept", "application/vnd.github+json")
        .timeout(std::time::Duration::from_secs(12));
    if !token.is_empty() {
        req = req.set("Authorization", &format!("Bearer {token}"));
    }
    match req.call() {
        Ok(r) => {
            let body = r.into_string().unwrap_or_default();
            serde_json::from_str::<Value>(&body).map_err(|e| format!("解析失败: {e}"))
        }
        Err(e) => Err(format!("网络请求失败: {e}")),
    }
}

#[cfg(windows)]
fn http_json(url: &str, token: &str) -> Result<Value, String> {
    let mut headers = "'User-Agent'='QWGuard';'Accept'='application/vnd.github+json'".to_string();
    if !token.is_empty() {
        headers.push_str(&format!(";'Authorization'='Bearer {token}'"));
    }
    let script = format!(
        "$ProgressPreference='SilentlyContinue';$h=@{{{headers}}};try{{(Invoke-RestMethod -Uri '{url}' -Headers $h -TimeoutSec 12 | ConvertTo-Json -Depth 4 -Compress)}}catch{{Write-Output \"__ERR__ $($_.Exception.Message)\"}}"
    );
    match Command::new("powershell").args(["-NoProfile", "-Command", &script]).output() {
        Ok(o) => {
            let text = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if let Some(msg) = text.strip_prefix("__ERR__") {
                return Err(format!("网络请求失败:{msg}"));
            }
            serde_json::from_str::<Value>(&text).map_err(|e| format!("解析失败: {e}"))
        }
        Err(e) => Err(format!("调用 PowerShell 失败: {e}")),
    }
}

#[no_mangle]
pub extern "C" fn check_update(repo: *const c_char, current: *const c_char, buf: *mut u8, len: usize) -> i32 {
    let (Some(repo), Some(current)) = (cstr(repo), cstr(current)) else {
        return fail(buf, len, -1, "参数为空");
    };
    if repo.is_empty() {
        return fail(buf, len, -1, "未配置 GitHub 仓库");
    }
    let url = format!("https://api.github.com/repos/{repo}/releases/latest");
    let token = load_config()
        .get("github_token")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    match http_json(&url, &token) {
        Ok(v) => {
            let tag = v.get("tag_name").and_then(|x| x.as_str()).unwrap_or("");
            let html = v.get("html_url").and_then(|x| x.as_str()).unwrap_or("");
            let notes = v.get("body").and_then(|x| x.as_str()).unwrap_or("");
            let published = v.get("published_at").and_then(|x| x.as_str()).unwrap_or("");
            ok(buf, len, "检查完成", json!({
                "latest": tag,
                "current": current,
                "has_update": newer(tag, &current),
                "url": html,
                "notes": notes.chars().take(500).collect::<String>(),
                "published_at": published
            }))
        }
        Err(e) => fail(buf, len, -3, &format!("{e}（若为 403 限流，可在设置里填 GitHub Token）")),
    }
}

// ================= 白名单 =================

fn wl_path() -> PathBuf {
    cfg_dir().join("whitelist.json")
}

fn load_wl() -> Vec<String> {
    fs::read_to_string(wl_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_wl(list: &[String]) {
    let _ = fs::create_dir_all(cfg_dir());
    let _ = fs::write(wl_path(), serde_json::to_string(list).unwrap_or_else(|_| "[]".into()));
}

pub fn is_whitelisted(path: &str) -> bool {
    let p = path.replace('\\', "/").to_lowercase();
    load_wl().iter().any(|w| {
        let w = w.replace('\\', "/").to_lowercase();
        p == w || p.starts_with(&format!("{w}/"))
    })
}

#[no_mangle]
pub extern "C" fn whitelist_add(path: *const c_char, buf: *mut u8, len: usize) -> i32 {
    let Some(p) = cstr(path) else { return fail(buf, len, -1, "参数为空") };
    let mut list = load_wl();
    if !list.iter().any(|x| x.eq_ignore_ascii_case(&p)) {
        list.push(p.clone());
        save_wl(&list);
    }
    ok(buf, len, "已加入白名单", json!({"path": p, "count": list.len()}))
}

#[no_mangle]
pub extern "C" fn whitelist_remove(path: *const c_char, buf: *mut u8, len: usize) -> i32 {
    let Some(p) = cstr(path) else { return fail(buf, len, -1, "参数为空") };
    let mut list = load_wl();
    list.retain(|x| !x.eq_ignore_ascii_case(&p));
    save_wl(&list);
    ok(buf, len, "已移出白名单", json!({"path": p, "count": list.len()}))
}

#[no_mangle]
pub extern "C" fn whitelist_list(buf: *mut u8, len: usize) -> i32 {
    ok(buf, len, "白名单", json!({"items": load_wl()}))
}

// ================= 多线程扫描 =================

/// 目标路径所在盘是不是机械盘（决定遍历要不要并行）
/// 机械盘并发遍历会因寻道抖动变慢，NVMe 有多队列，并发才吃得满
fn is_mechanical(path: &Path) -> bool {
    use sysinfo::{DiskKind, Disks};
    let disks = Disks::new_with_refreshed_list();
    let mut best: Option<(&Path, DiskKind)> = None;
    for d in disks.list() {
        let mp = d.mount_point();
        if path.starts_with(mp) {
            let deeper = best
                .map(|(m, _)| mp.as_os_str().len() > m.as_os_str().len())
                .unwrap_or(true);
            if deeper {
                best = Some((mp, d.kind()));
            }
        }
    }
    matches!(best.map(|(_, k)| k), Some(DiskKind::HDD))
}

pub(crate) fn walk(p: &Path, out: &mut Vec<PathBuf>, depth: usize) {
    if depth == 0 {
        return;
    }
    // 逐层推进：同一层子目录并行读（NVMe 吃多队列）；机械盘或目录太少时串行
    let mechanical = is_mechanical(p);
    let mut frontier: Vec<PathBuf> = vec![p.to_path_buf()];
    let mut level = 0usize;

    while !frontier.is_empty() && level < depth {
        if mechanical || frontier.len() < 4 {
            let mut next = Vec::new();
            for d in &frontier {
                let Ok(rd) = fs::read_dir(d) else { continue };
                for e in rd.flatten() {
                    let path = e.path();
                    let Ok(meta) = fs::symlink_metadata(&path) else { continue };
                    if meta.file_type().is_symlink() {
                        continue;
                    }
                    if meta.is_file() {
                        out.push(path);
                    } else {
                        next.push(path);
                    }
                }
            }
            frontier = next;
        } else {
            let batch: Vec<(Vec<PathBuf>, Vec<PathBuf>)> = frontier
                .par_iter()
                .map(|d| {
                    let mut files = Vec::new();
                    let mut dirs = Vec::new();
                    let Ok(rd) = fs::read_dir(d) else { return (files, dirs) };
                    for e in rd.flatten() {
                        let path = e.path();
                        let Ok(meta) = fs::symlink_metadata(&path) else { continue };
                        if meta.file_type().is_symlink() {
                            continue;
                        }
                        if meta.is_file() {
                            files.push(path);
                        } else {
                            dirs.push(path);
                        }
                    }
                    (files, dirs)
                })
                .collect();
            let mut next = Vec::new();
            for (files, dirs) in batch {
                out.extend(files);
                next.extend(dirs);
            }
            frontier = next;
        }
        level += 1;
    }
}

#[no_mangle]
pub extern "C" fn scan_dir_fast(dir: *const c_char, buf: *mut u8, len: usize) -> i32 {
    let Some(dir) = cstr(dir) else { return fail(buf, len, -1, "参数为空") };
    let root = Path::new(&dir);
    if !root.exists() {
        return fail(buf, len, -3, "目录不存在");
    }
    let t0 = std::time::Instant::now();
    let mut files = Vec::new();
    walk(root, &mut files, 12);
    let total: u64 = files
        .par_iter()
        .map(|p| fs::metadata(p).map(|m| m.len()).unwrap_or(0))
        .sum();
    ok(buf, len, "多线程统计完成", json!({
        "files": files.len(),
        "bytes": total,
        "elapsed_ms": t0.elapsed().as_millis(),
        "threads": rayon::current_num_threads()
    }))
}

// ================= CPU 画像（大小核提示） =================

#[no_mangle]
pub extern "C" fn cpu_profile(buf: *mut u8, len: usize) -> i32 {
    use sysinfo::System;
    let sys = System::new_all();
    let brand = sys.cpus().first().map(|c| c.brand().trim().to_string()).unwrap_or_default();
    let lower = brand.to_lowercase();
    let hybrid = lower.contains("12th") || lower.contains("13th") || lower.contains("14th")
        || lower.contains("core ultra") || lower.contains("ryzen 7 7") || lower.contains("ryzen 9 7");
    ok(buf, len, "CPU 画像", json!({
        "brand": brand,
        "cores": sys.cpus().len(),
        "hybrid": hybrid,
        "can_schedule": cfg!(windows) && hybrid,
        "note": if hybrid {
            "检测到混合架构；大小核调度需 Win11 + SetThreadInformation，默认交给系统调度"
        } else {
            "未检测到混合架构，使用统一调度"
        }
    }))
}

// ================= 智能查杀（按显卡强弱选策略 + 多引擎并发） =================

#[derive(Serialize)]
struct EngineOutcome {
    engine: String,
    ok: bool,
    infected: bool,
    threats: Vec<String>,
    message: String,
}

#[no_mangle]
pub extern "C" fn scan_auto(target: *const c_char, buf: *mut u8, len: usize) -> i32 {
    let Some(target) = cstr(target) else { return fail(buf, len, -1, "参数为空") };
    // 每次查杀前确保规则库落地（首次运行会写入内置 YARA 与空哈希库）
    crate::engines::ensure_default_rules();
    if !Path::new(&target).exists() {
        return fail(buf, len, -3, "目标路径不存在");
    }
    if is_whitelisted(&target) {
        return ok(buf, len, "已跳过（白名单）", json!({"skipped": true, "engines": []}));
    }

    // 并发度看 CPU 核心数，跟显卡无关：显卡只决定渲染偏好（apply_gpu_preference），
    // 不该决定杀毒跑几个引擎。以前按独显分数选引擎是错的，这里改掉。
    let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);

    // 档位决定"用几把刀"，跟显卡无关。ClamAV 已摘除（国内拉不到病毒库，空壳引擎没有意义），
    // 四引擎全部自带，用户零安装。
    //   quick    ：Defender + 启发式      —— 快，不解全文件哈希
    //   standard ：Defender + 特征库 + 启发式
    //   deep     ：再叠加 YARA 规则
    let level = load_config()
        .get("scan_level")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .unwrap_or_else(|| "standard".to_string());

    let (mode, engines): (&str, Vec<&str>) = match level.as_str() {
        "quick" => ("quick", vec!["defender", "heuristic"]),
        "deep" => (
            "deep",
            vec!["defender", "signature", "heuristic", "yara"],
        ),
        _ => ("standard", vec!["defender", "signature", "heuristic"]),
    };

    let mut handles = Vec::new();
    for engine in engines {
        let engine_s = engine.to_string();
        let target_s = target.clone();
        handles.push(std::thread::spawn(move || {
            match crate::run_engine(&engine_s, &target_s) {
                Ok((infected, threats)) => EngineOutcome {
                    engine: engine_s,
                    ok: true,
                    infected,
                    threats,
                    message: String::new(),
                },
                Err(e) => EngineOutcome {
                    engine: engine_s,
                    ok: false,
                    infected: false,
                    threats: Vec::new(),
                    message: e,
                },
            }
        }));
    }

    let results: Vec<EngineOutcome> = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .collect();

    let any_infected = results.iter().any(|r| r.infected);
    ok(buf, len, "QW 引擎查杀完成", json!({
        "target": target,
        "engine": "QW",
        "mode": mode,
        "cores": cores,
        "infected": any_infected,
        "engines": results
    }))
}


// ================= 渲染显卡偏好（按厂商判定，写入系统 GPU 偏好） =================

#[derive(Clone, Copy)]
enum RenderTier {
    High,
    PowerSaving,
}

/// 把"本程序用哪块显卡渲染"写入 Windows 的 per-app GPU 偏好
/// 路径：HKCU\Software\Microsoft\DirectX\UserGpuPreferences
/// 值：GpuPreference=2; 高性能（独显） / GpuPreference=1; 省电（核显）
/// 生效时机：下次启动本程序（系统在进程启动时读取）
#[no_mangle]
pub extern "C" fn apply_gpu_preference(mode: *const c_char, buf: *mut u8, len: usize) -> i32 {
    let Some(mode) = cstr(mode) else { return fail(buf, len, -1, "参数为空") };

    let gpus = detect_gpus();
    if gpus.is_empty() {
        return fail(buf, len, -3, "未检测到显卡");
    }

    let want = match mode.as_str() {
        "auto" => recommend_gpu(&gpus),
        "discrete" => "discrete".to_string(),
        "integrated" => "integrated".to_string(),
        _ => return fail(buf, len, -1, "未知模式"),
    };

    let chosen = gpus
        .iter()
        .filter(|g| g.kind == want)
        .max_by_key(|g| g.score)
        .cloned();

    let Some(chosen) = chosen else {
        return fail(buf, len, -3, &format!("本机没有 {} 显卡，无法切换", if want == "discrete" { "独立" } else { "集成" }));
    };

    let tier = if want == "discrete" { RenderTier::High } else { RenderTier::PowerSaving };
    let value = match tier {
        RenderTier::High => "GpuPreference=2;",
        RenderTier::PowerSaving => "GpuPreference=1;",
    };

    let exe = std::env::current_exe()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_default();

    if cfg!(windows) {
        let out = Command::new("reg")
            .args([
                "add",
                r"HKCU\Software\Microsoft\DirectX\UserGpuPreferences",
                "/v",
                &exe,
                "/t",
                "REG_SZ",
                "/d",
                value,
                "/f",
            ])
            .output();
        match out {
            Ok(o) if o.status.success() => ok(buf, len, "已写入系统 GPU 偏好", json!({
                "mode": mode,
                "applied": true,
                "tier": if matches!(tier, RenderTier::High) { "high" } else { "power_saving" },
                "gpu": chosen.name,
                "vendor": chosen.vendor,
                "kind": chosen.kind,
                "exe": exe,
                "note": "重启本程序后生效；若显卡驱动有自己的游戏/程序配置，以其为准"
            })),
            _ => fail(buf, len, -3, "写入注册表失败（可能需要权限）"),
        }
    } else {
        ok(buf, len, "非 Windows：仅返回建议，不写系统偏好", json!({
            "mode": mode,
            "applied": false,
            "gpu": chosen.name,
            "vendor": chosen.vendor,
            "kind": chosen.kind,
            "note": "本机不是 Windows，无法设置 DXGI 偏好"
        }))
    }
}

// ================= 火绒 / PYAS 集成 =================

fn tool_path(key: &str, candidates: &[&str]) -> Option<String> {
    if let Some(p) = load_config().get(key).and_then(|v| v.as_str()) {
        if !p.is_empty() && Path::new(p).exists() {
            return Some(p.to_string());
        }
    }
    candidates
        .iter()
        .find(|p| Path::new(p).exists())
        .map(|s| s.to_string())
}

fn looks_infected(text: &str) -> (bool, Vec<String>) {
    let keys = ["FOUND", "Detected", "infected", "病毒", "木马", "风险", "威胁", "恶意"];
    let hits: Vec<String> = text
        .lines()
        .filter(|l| keys.iter().any(|k| l.contains(k)))
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .take(50)
        .collect();
    (!hits.is_empty(), hits)
}

/// 火绒 hrscan：有命令行就命令行扫描，没有则退回主程序启动
#[no_mangle]
pub extern "C" fn scan_huorong(target: *const c_char, buf: *mut u8, len: usize) -> i32 {
    let Some(target) = cstr(target) else { return fail(buf, len, -1, "参数为空") };
    if !Path::new(&target).exists() {
        return fail(buf, len, -3, "目标路径不存在");
    }
    if is_whitelisted(&target) {
        return ok(buf, len, "已跳过（白名单）", json!({"engine": "huorong", "skipped": true, "infected": false}));
    }

    let Some(exe) = tool_path("huorong_path", &[
        "C:\\Program Files\\Huorong\\Sysdiag\\bin\\hrscan.exe",
        "C:\\Program Files (x86)\\Huorong\\Sysdiag\\bin\\hrscan.exe",
        "C:\\Program Files\\Huorong\\Sysdiag\\bin\\HipsMain.exe",
    ]) else {
        return fail(buf, len, -3, "未找到火绒（可在设置里填 huorong_path）");
    };

    match Command::new(&exe).arg(&target).output() {
        Ok(o) => {
            let text = format!(
                "{}{}",
                String::from_utf8_lossy(&o.stdout),
                String::from_utf8_lossy(&o.stderr)
            );
            let (infected, threats) = looks_infected(&text);
            ok(buf, len, "火绒扫描完成", json!({
                "engine": "huorong",
                "exe": exe,
                "mode": if text.trim().is_empty() { "launched" } else { "cli" },
                "infected": infected,
                "threats": threats,
                "note": if text.trim().is_empty() {
                    "当前版本未返回命令行输出，已启动扫描进程；结果以火绒界面为准"
                } else { "" }
            }))
        }
        Err(e) => fail(buf, len, -3, &format!("调用火绒失败: {e}")),
    }
}

fn collect_logs(dir: &Path, since: std::time::SystemTime, depth: usize, out: &mut Vec<(std::time::SystemTime, std::path::PathBuf)>) {
    if depth == 0 {
        return;
    }
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        let Ok(meta) = fs::symlink_metadata(&p) else { continue };
        if meta.is_dir() {
            collect_logs(&p, since, depth - 1, out);
        } else if meta.is_file() {
            let ok_ext = p
                .extension()
                .map(|x| {
                    let s = x.to_string_lossy().to_lowercase();
                    s == "log" || s == "txt" || s == "json"
                })
                .unwrap_or(false);
            if ok_ext {
                if let Ok(m) = meta.modified() {
                    if m >= since {
                        out.push((m, p));
                    }
                }
            }
        }
    }
}

/// PYAS：没有命令行与 SDK，只能启动 + 尽量从日志里捞结果
#[no_mangle]
pub extern "C" fn scan_pyas(target: *const c_char, buf: *mut u8, len: usize) -> i32 {
    let Some(target) = cstr(target) else { return fail(buf, len, -1, "参数为空") };
    if !Path::new(&target).exists() {
        return fail(buf, len, -3, "目标路径不存在");
    }
    if is_whitelisted(&target) {
        return ok(buf, len, "已跳过（白名单）", json!({"engine": "pyas", "skipped": true, "infected": false}));
    }

    let Some(exe) = tool_path("pyas_path", &[
        "C:\\Program Files\\PYAS\\PYAS.exe",
        "C:\\Program Files (x86)\\PYAS\\PYAS.exe",
        "C:\\Program Files\\PYAS Security\\PYAS.exe",
    ]) else {
        return fail(buf, len, -3, "未找到 PYAS（可在设置里填 pyas_path）");
    };

    let start = std::time::SystemTime::now();
    let spawned = Command::new(&exe).arg(&target).spawn();

    // 等待最多 12 秒，轮询日志
    let mut dirs: Vec<std::path::PathBuf> = Vec::new();
    for base in ["APPDATA", "LOCALAPPDATA"] {
        if let Ok(v) = std::env::var(base) {
            dirs.push(Path::new(&v).join("PYAS"));
            dirs.push(Path::new(&v).join("PYAS Security"));
        }
    }
    if let Some(parent) = Path::new(&exe).parent() {
        dirs.push(parent.join("logs"));
        dirs.push(parent.join("log"));
    }

    let mut newest: Option<(std::time::SystemTime, std::path::PathBuf)> = None;
    for _ in 0..24 {
        let mut found = Vec::new();
        for d in &dirs {
            collect_logs(d, start, 2, &mut found);
        }
        if let Some(mx) = found.into_iter().max_by_key(|(t, _)| *t) {
            newest = Some(mx);
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }

    let launched_ok = spawned.is_ok();
    let (infected, threats, log_path) = match newest {
        Some((_, p)) => {
            let text = fs::read_to_string(&p).unwrap_or_default();
            let tail: String = text.lines().rev().take(300).collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>().join("\n");
            let (i, t) = looks_infected(&tail);
            (i, t, p.to_string_lossy().to_string())
        }
        None => (false, Vec::new(), String::new()),
    };

    ok(buf, len, "PYAS 处理完成", json!({
        "engine": "pyas",
        "exe": exe,
        "mode": "best_effort",
        "launched": launched_ok,
        "infected": infected,
        "threats": threats,
        "log": log_path,
        "note": if log_path.is_empty() {
            "PYAS 无命令行接口，已启动主程序；未找到可解析日志，结果请在 PYAS 界面查看"
        } else {
            "结果来自 PYAS 新生成的日志，可能不完整"
        }
    }))
}
