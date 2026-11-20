//! 密码保护 / 后台调度 / 空闲判定 / 安全策略设置
//!
//! 用户的几条要求落在这里：
//! - 密码管理默认关闭；开启后退出后台再打开、关自启动、关后台查杀、关闭软件都要验密码
//! - 后台清理与查杀频率可配（1/2/4/6/8/12/24 小时、1~5 天、自定义、关闭）
//! - 只有系统空闲时才动手，别跟用户抢资源
//! - 发现病毒的处理方式：自动处理 / 询问我 / 仅记录，默认询问我
//! - 静默安装更新可关闭（关闭时前端弹二级确认）

use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::ffi::c_char;
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::ext::{cfg_dir, load_config, save_config};
use crate::{cstr, fail, ok};

/// 后台线程是否在跑
static BG_RUNNING: AtomicBool = AtomicBool::new(false);

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ================= 密码 =================

fn pwd_path() -> PathBuf {
    cfg_dir().join("pwd.json")
}

fn hash_of(salt: &str, pwd: &str) -> String {
    let mut h = Sha256::new();
    h.update(salt.as_bytes());
    h.update(b"|qw|");
    h.update(pwd.as_bytes());
    h.finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn make_salt() -> String {
    let d = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    format!("{:x}{:x}{:x}", d.as_secs(), d.subsec_nanos(), std::process::id())
}

fn read_pwd() -> Option<(String, String)> {
    let text = fs::read_to_string(pwd_path()).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    let salt = v.get("salt")?.as_str()?.to_string();
    let hash = v.get("hash")?.as_str()?.to_string();
    if salt.is_empty() || hash.is_empty() {
        return None;
    }
    Some((salt, hash))
}

/// 设置密码（首次设置或修改；修改时不校验旧密码，旧密码在 UI 层先验）
#[no_mangle]
pub extern "C" fn password_set(pwd: *const c_char, buf: *mut u8, len: usize) -> i32 {
    let Some(p) = cstr(pwd) else {
        return fail(buf, len, -1, "密码为空");
    };
    if p.len() < 4 {
        return fail(buf, len, -1, "密码至少 4 位");
    }
    let salt = make_salt();
    let hash = hash_of(&salt, &p);
    let _ = fs::create_dir_all(cfg_dir());
    let body = json!({"salt": salt, "hash": hash, "updated": now_secs()});
    match fs::write(pwd_path(), body.to_string()) {
        Ok(_) => {
            // 打开密码保护开关
            let mut cfg = load_config();
            if let Value::Object(ref mut m) = cfg {
                m.insert("pwd_enabled".into(), Value::Bool(true));
            }
            save_config(&cfg);
            ok(buf, len, "密码已设置", json!({"enabled": true}))
        }
        Err(e) => fail(buf, len, -3, &format!("写入失败: {e}")),
    }
}

/// 校验密码
#[no_mangle]
pub extern "C" fn password_verify(pwd: *const c_char, buf: *mut u8, len: usize) -> i32 {
    let Some(p) = cstr(pwd) else {
        return fail(buf, len, -1, "密码为空");
    };
    match read_pwd() {
        Some((salt, hash)) => {
            if hash_of(&salt, &p) == hash {
                ok(buf, len, "验证通过", json!({"ok": true}))
            } else {
                fail(buf, len, -3, "密码错误")
            }
        }
        None => fail(buf, len, -3, "尚未设置密码"),
    }
}

/// 关闭密码保护并删除凭据
#[no_mangle]
pub extern "C" fn password_clear(buf: *mut u8, len: usize) -> i32 {
    let _ = fs::remove_file(pwd_path());
    let mut cfg = load_config();
    if let Value::Object(ref mut m) = cfg {
        m.insert("pwd_enabled".into(), Value::Bool(false));
    }
    save_config(&cfg);
    ok(buf, len, "密码保护已关闭", json!({"enabled": false}))
}

/// 密码状态
#[no_mangle]
pub extern "C" fn password_state(buf: *mut u8, len: usize) -> i32 {
    let exists = read_pwd().is_some();
    let enabled = load_config()
        .get("pwd_enabled")
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
        && exists;
    ok(buf, len, "密码状态", json!({"enabled": enabled, "has_password": exists}))
}

// ================= 安全策略设置 =================

/// 一次性返回所有安全相关配置，前端只调一次
#[no_mangle]
pub extern "C" fn security_settings(buf: *mut u8, len: usize) -> i32 {
    let cfg = load_config();
    let g = |k: &str, d: Value| cfg.get(k).cloned().unwrap_or(d);
    ok(
        buf,
        len,
        "安全设置",
        json!({
            "pwd_enabled": g("pwd_enabled", json!(false)),
            "clean_interval_min": g("clean_interval_min", json!(0)),
            "scan_interval_min": g("scan_interval_min", json!(0)),
            "idle_only": g("idle_only", json!(true)),
            "virus_action": g("virus_action", json!("ask")),      // auto / ask / record
            "silent_update": g("silent_update", json!(true)),
            "trust_dir": g("trust_dir", json!([])),
            "autostart_enabled": g("autostart_enabled", json!(false)),
            "bg_last_clean": g("bg_last_clean", json!(0)),
            "bg_last_scan": g("bg_last_scan", json!(0)),
            "bg_running": json!(BG_RUNNING.load(Ordering::SeqCst))
        }),
    )
}

/// 写一项安全配置
#[no_mangle]
pub extern "C" fn security_set(
    key: *const c_char,
    value: *const c_char,
    buf: *mut u8,
    len: usize,
) -> i32 {
    let (Some(k), Some(v)) = (cstr(key), cstr(value)) else {
        return fail(buf, len, -1, "参数为空");
    };
    let mut cfg = load_config();
    let parsed = serde_json::from_str::<Value>(&v).unwrap_or(Value::String(v.clone()));
    if let Value::Object(ref mut m) = cfg {
        m.insert(k.clone(), parsed);
    }
    save_config(&cfg);
    ok(buf, len, "已保存", json!({"key": k, "value": v}))
}

// ================= 空闲判定 =================

/// 系统是否空闲：CPU 负载低于 20% 且内存有 25% 以上空余
pub(crate) fn is_idle() -> bool {
    use sysinfo::System;
    let mut sys = System::new();
    sys.refresh_cpu_usage();
    // 两次采样取平均，第一次刚 new 出来是 0
    std::thread::sleep(Duration::from_millis(600));
    sys.refresh_cpu_usage();
    sys.refresh_memory();

    let cpu = sys.global_cpu_info().cpu_usage();
    let total = sys.total_memory();
    let avail = sys.available_memory();
    if total == 0 {
        return true;
    }
    let free_ratio = avail as f32 / total as f32;
    cpu < 20.0 && free_ratio > 0.25
}

#[no_mangle]
pub extern "C" fn idle_state(buf: *mut u8, len: usize) -> i32 {
    ok(buf, len, "空闲状态", json!({"idle": is_idle()}))
}

// ================= 后台任务 =================

/// 后台线程：每 30 秒醒一次，看有没有到点的清理/查杀任务
fn bg_loop() {
    loop {
        if !BG_RUNNING.load(Ordering::SeqCst) {
            break;
        }
        std::thread::sleep(Duration::from_secs(30));
        if !BG_RUNNING.load(Ordering::SeqCst) {
            break;
        }

        let cfg = load_config();
        let clean_min = cfg.get("clean_interval_min").and_then(|v| v.as_u64()).unwrap_or(0);
        let scan_min = cfg.get("scan_interval_min").and_then(|v| v.as_u64()).unwrap_or(0);
        let idle_only = cfg.get("idle_only").and_then(|v| v.as_bool()).unwrap_or(true);
        let now = now_secs();

        if clean_min == 0 && scan_min == 0 {
            continue;
        }
        if idle_only && !is_idle() {
            continue;
        }

        let mut cfg2 = load_config();
        let mut changed = false;

        // 垃圾清理到点
        if clean_min > 0 {
            let last = cfg.get("bg_last_clean").and_then(|v| v.as_u64()).unwrap_or(0);
            if now.saturating_sub(last) >= clean_min * 60 {
                let (freed, deleted) = crate::clean_all_quiet();
                if let Value::Object(ref mut m) = cfg2 {
                    m.insert("bg_last_clean".into(), json!(now));
                    m.insert("bg_last_freed".into(), json!(freed));
                    m.insert("bg_last_deleted".into(), json!(deleted));
                }
                changed = true;
                crate::bg_log(&format!(
                    "[{}] 后台清理完成，释放 {} 字节，删除 {} 个文件",
                    now, freed, deleted
                ));
            }
        }

        // 查杀到点
        if scan_min > 0 {
            let last = cfg.get("bg_last_scan").and_then(|v| v.as_u64()).unwrap_or(0);
            if now.saturating_sub(last) >= scan_min * 60 {
                let found = crate::scan_common_dirs_quiet();
                if let Value::Object(ref mut m) = cfg2 {
                    m.insert("bg_last_scan".into(), json!(now));
                    m.insert("bg_last_found".into(), json!(found));
                }
                changed = true;
                crate::bg_log(&format!("[{}] 后台查杀完成，命中 {} 项", now, found));
            }
        }

        if changed {
            save_config(&cfg2);
        }
    }
}

/// 开启后台任务
#[no_mangle]
pub extern "C" fn bg_start(buf: *mut u8, len: usize) -> i32 {
    if BG_RUNNING.swap(true, Ordering::SeqCst) {
        return ok(buf, len, "后台任务已在运行", json!({"running": true}));
    }
    std::thread::spawn(bg_loop);
    ok(buf, len, "后台任务已启动", json!({"running": true}))
}

/// 停止后台任务
#[no_mangle]
pub extern "C" fn bg_stop(buf: *mut u8, len: usize) -> i32 {
    BG_RUNNING.store(false, Ordering::SeqCst);
    ok(buf, len, "后台任务已停止", json!({"running": false}))
}

/// 后台状态 + 最近一次结果
#[no_mangle]
pub extern "C" fn bg_status(buf: *mut u8, len: usize) -> i32 {
    let cfg = load_config();
    ok(
        buf,
        len,
        "后台状态",
        json!({
            "running": BG_RUNNING.load(Ordering::SeqCst),
            "last_clean": cfg.get("bg_last_clean").and_then(|v| v.as_u64()).unwrap_or(0),
            "last_scan": cfg.get("bg_last_scan").and_then(|v| v.as_u64()).unwrap_or(0),
            "last_freed": cfg.get("bg_last_freed").and_then(|v| v.as_u64()).unwrap_or(0),
            "last_deleted": cfg.get("bg_last_deleted").and_then(|v| v.as_u64()).unwrap_or(0),
            "last_found": cfg.get("bg_last_found").and_then(|v| v.as_u64()).unwrap_or(0)
        }),
    )
}

/// 立即跑一轮（不管到没到点）
#[no_mangle]
pub extern "C" fn bg_run_once(buf: *mut u8, len: usize) -> i32 {
    let (freed, deleted) = crate::clean_all_quiet();
    let found = crate::scan_common_dirs_quiet();
    let now = now_secs();
    let mut cfg = load_config();
    if let Value::Object(ref mut m) = cfg {
        m.insert("bg_last_clean".into(), json!(now));
        m.insert("bg_last_scan".into(), json!(now));
        m.insert("bg_last_freed".into(), json!(freed));
        m.insert("bg_last_deleted".into(), json!(deleted));
        m.insert("bg_last_found".into(), json!(found));
    }
    save_config(&cfg);
    crate::bg_log(&format!(
        "[{}] 手动执行一轮：释放 {} 字节，删除 {} 个文件，命中 {} 项",
        now, freed, deleted, found
    ));
    ok(
        buf,
        len,
        "执行完成",
        json!({"freed": freed, "deleted": deleted, "found": found}),
    )
}
