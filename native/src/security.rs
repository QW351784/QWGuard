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
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::ext::{cfg_dir, load_config, save_config};
use crate::{cstr, fail, ok};

/// 后台线程是否在跑
static BG_RUNNING: AtomicBool = AtomicBool::new(false);
/// 最近一次密码验证通过的时间（秒）。关闭密码保护必须先验证，防止谁都能一键关掉。
static AUTH_UNTIL: AtomicU64 = AtomicU64::new(0);
/// 一次密码验证只允许紧接着执行一个高危动作；窗口压到 5 秒，
/// 不再是以前“验证一次、60 秒内随便调 DLL”的宽窗口。
const AUTH_TTL_SECS: u64 = 5;
/// 连续输错计数与锁定截止时间：即使 PBKDF2，也不能让人在接口上无限试
static PWD_FAILS: AtomicU32 = AtomicU32::new(0);
static PWD_LOCK_UNTIL: AtomicU64 = AtomicU64::new(0);

// ================= 密码 =================

fn pwd_path() -> PathBuf {
    cfg_dir().join("pwd.json")
}

const PBKDF2_ITER: u32 = 120_000;

enum Pwd {
    /// 老格式：单轮 SHA-256(salt|qw|pwd)，只用于兼容升级
    V1 { salt: String, hash: String },
    /// 新格式：PBKDF2-HMAC-SHA256，120k 轮
    V2 {
        salt: Vec<u8>,
        iter: u32,
        hash: Vec<u8>,
    },
}

fn hex_of(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 || !s.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    (0..s.len() / 2)
        .map(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).ok())
        .collect()
}

fn rand_bytes(n: usize) -> Vec<u8> {
    let mut v = vec![0u8; n];
    if getrandom::getrandom(&mut v).is_err() {
        // 极端情况下退化到时间+进程，仍然保证每次密码设置 salt 不同
        let d = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        let seed = format!(
            "{}:{}:{}",
            d.as_secs(),
            d.subsec_nanos(),
            std::process::id()
        );
        let mut h = Sha256::new();
        h.update(seed.as_bytes());
        let out = h.finalize();
        for (i, b) in v.iter_mut().enumerate() {
            *b = out[i % out.len()];
        }
    }
    v
}

fn derive(salt: &[u8], pwd: &str, iter: u32) -> Vec<u8> {
    use hmac::Hmac;
    type HmacSha256 = Hmac<Sha256>;
    let mut out = [0u8; 32];
    pbkdf2::pbkdf2::<HmacSha256>(pwd.as_bytes(), salt, iter, &mut out)
        .expect("32 字节输出长度合法");
    out.to_vec()
}

fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for i in 0..a.len() {
        diff |= a[i] ^ b[i];
    }
    diff == 0
}

fn read_pwd() -> Option<Pwd> {
    let text = fs::read_to_string(pwd_path()).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    let ver = v.get("v").and_then(|x| x.as_u64()).unwrap_or(1);
    if ver >= 2 {
        let salt = unhex(v.get("salt")?.as_str()?)?;
        let iter = v
            .get("iter")
            .and_then(|x| x.as_u64())
            .unwrap_or(PBKDF2_ITER as u64) as u32;
        let hash = unhex(v.get("hash")?.as_str()?)?;
        if salt.is_empty() || hash.is_empty() || iter < 10_000 {
            return None;
        }
        Some(Pwd::V2 { salt, iter, hash })
    } else {
        let salt = v.get("salt")?.as_str()?.to_string();
        let hash = v.get("hash")?.as_str()?.to_string();
        if salt.is_empty() || hash.is_empty() {
            return None;
        }
        Some(Pwd::V1 { salt, hash })
    }
}

fn verify_pwd(rec: &Pwd, pwd: &str) -> bool {
    match rec {
        Pwd::V1 { salt, hash } => {
            let mut h = Sha256::new();
            h.update(salt.as_bytes());
            h.update(b"|qw|");
            h.update(pwd.as_bytes());
            let got = hex_of(&h.finalize());
            ct_eq(got.as_bytes(), hash.as_bytes())
        }
        Pwd::V2 { salt, iter, hash } => ct_eq(&derive(salt, pwd, *iter), hash),
    }
}

fn store_pwd(pwd: &str) -> Result<(), String> {
    let salt = rand_bytes(16);
    let hash = derive(&salt, pwd, PBKDF2_ITER);
    let body = json!({
        "v": 2,
        "algo": "pbkdf2-sha256",
        "iter": PBKDF2_ITER,
        "salt": hex_of(&salt),
        "hash": hex_of(&hash),
        "updated": crate::util::now_secs(),
    });
    crate::write_atomic(&pwd_path(), &body.to_string()).map_err(|e| format!("写入失败: {e}"))
}

/// 老格式验证成功后顺手升级成 PBKDF2，用户不用重新设密码
fn upgrade_if_legacy(rec: &Pwd, pwd: &str) {
    if matches!(rec, Pwd::V1 { .. }) && verify_pwd(rec, pwd) {
        let _ = store_pwd(pwd);
    }
}

/// 卸载前的密码闸门：只有「已设置密码」时才拦，没设置就照常卸。
/// 放在 Rust 层而不是只放在界面上，是因为控制面板会直接调 --uninstall，
/// 只拦 UI 等于没拦。
pub(crate) fn check_uninstall_pwd(pwd: &str) -> Result<(), &'static str> {
    match read_pwd() {
        None => {
            // 配置里明明开着密码保护，凭据文件却没了：多半是被手动删了。
            // 这种情况下放行等于「删个文件就能绕过」，直接拒绝；重装后可重新设密码。
            if load_config()
                .get("pwd_enabled")
                .and_then(|v| v.as_bool())
                .unwrap_or(false)
            {
                Err("密码凭据丢失（pwd.json 被删除或损坏），已拒绝卸载；请重新安装本程序后重置密码")
            } else {
                Ok(())
            }
        }
        Some(rec) => {
            if pwd.trim().is_empty() {
                return Err("已开启密码保护，卸载前必须输入密码");
            }
            if verify_pwd(&rec, pwd) {
                upgrade_if_legacy(&rec, pwd);
                Ok(())
            } else {
                Err("密码错误，无法卸载")
            }
        }
    }
}

/// 设置密码（首次设置或修改；修改时不校验旧密码，旧密码在 UI 层先验）
#[no_mangle]
pub extern "C" fn password_set(pwd: *const c_char, buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        let Some(p) = cstr(pwd) else {
            return fail(buf, len, -1, "密码为空");
        };
        if p.chars().count() < 8 {
            return fail(buf, len, -1, "密码至少 8 位（数字、字母都算一位）");
        }
        // 已经开启密码保护时，改密码必须先验旧密码；否则谁都能直接调 DLL
        // 覆盖 pwd.json，再用自己的密码通过严格模式。
        let had_pwd = pwd_enabled();
        if had_pwd && crate::util::now_secs() > AUTH_UNTIL.load(Ordering::SeqCst) {
            return fail(buf, len, -5, "修改密码前需要先验证旧密码");
        }
        match store_pwd(&p) {
            Ok(_) => {
                if had_pwd {
                    AUTH_UNTIL.store(0, Ordering::SeqCst);
                }
                // 打开密码保护开关
                let mut cfg = load_config();
                if let Value::Object(ref mut m) = cfg {
                    m.insert("pwd_enabled".into(), Value::Bool(true));
                }
                save_config(&cfg);
                let msg = if had_pwd {
                    "密码已修改"
                } else {
                    "密码已设置"
                };
                ok(buf, len, msg, json!({"enabled": true}))
            }
            Err(e) => fail(buf, len, -3, &e),
        }
    })
}

/// 校验密码
#[no_mangle]
pub extern "C" fn password_verify(pwd: *const c_char, buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        let Some(p) = cstr(pwd) else {
            return fail(buf, len, -1, "密码为空");
        };
        let now = crate::util::now_secs();
        if now < PWD_LOCK_UNTIL.load(Ordering::SeqCst) {
            return fail(buf, len, -3, "密码错误次数过多，请 60 秒后再试");
        }
        match read_pwd() {
            Some(rec) => {
                if verify_pwd(&rec, &p) {
                    upgrade_if_legacy(&rec, &p);
                    AUTH_UNTIL.store(now + AUTH_TTL_SECS, Ordering::SeqCst);
                    PWD_FAILS.store(0, Ordering::SeqCst);
                    ok(buf, len, "验证通过", json!({"ok": true}))
                } else {
                    let n = PWD_FAILS.fetch_add(1, Ordering::SeqCst) + 1;
                    if n >= 5 {
                        PWD_FAILS.store(0, Ordering::SeqCst);
                        PWD_LOCK_UNTIL.store(now + 60, Ordering::SeqCst);
                        return fail(buf, len, -3, "密码错误次数过多，已锁定 60 秒");
                    }
                    fail(buf, len, -3, "密码错误")
                }
            }
            None => fail(buf, len, -3, "尚未设置密码"),
        }
    })
}

/// 关闭密码保护并删除凭据
#[no_mangle]
pub extern "C" fn password_clear(buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        let has_rec = read_pwd().is_some();
        let cfg_enabled = load_config()
            .get("pwd_enabled")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        // 配置开着、凭据却没了：不能让人用「关闭密码」这一步把闸门顺手拆掉
        if cfg_enabled && !has_rec {
            return fail(
                buf,
                len,
                -5,
                "密码凭据已丢失，不能直接关闭密码保护；请重新安装后重置密码",
            );
        }
        // 已设置密码时，必须先验证通过；验证通过后这次授权只用于关闭密码，
        // 用掉即失效，避免同一窗口再被拿去调别的接口。
        if has_rec {
            if crate::util::now_secs() > AUTH_UNTIL.load(Ordering::SeqCst) {
                return fail(buf, len, -5, "关闭密码保护前需要先验证密码");
            }
            AUTH_UNTIL.store(0, Ordering::SeqCst);
        }
        let _ = fs::remove_file(pwd_path());
        let mut cfg = load_config();
        if let Value::Object(ref mut m) = cfg {
            m.insert("pwd_enabled".into(), Value::Bool(false));
        }
        save_config(&cfg);
        ok(buf, len, "密码保护已关闭", json!({"enabled": false}))
    })
}

/// 密码保护是否开启：配置标记或凭据文件任一存在都算。
/// 这样删掉 config.json 不会把严格模式关掉；删掉 pwd.json 也不会让界面
/// 误以为「没设密码」而直接放行（只是验证会失败，需要重装恢复）。
fn pwd_enabled() -> bool {
    let cfg_on = load_config()
        .get("pwd_enabled")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    cfg_on || read_pwd().is_some()
}

/// 密码状态
#[no_mangle]
pub extern "C" fn password_state(buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        let exists = read_pwd().is_some();
        ok(
            buf,
            len,
            "密码状态",
            json!({"enabled": pwd_enabled(), "has_password": exists}),
        )
    })
}

/// 严格模式是否真正生效：密码凭据存在 + 配置未显式关闭（配置丢了按开启算）。
pub(crate) fn strict_active() -> bool {
    pwd_enabled()
        && load_config()
            .get("strict_mode")
            .and_then(|v| v.as_bool())
            .unwrap_or(true)
}

/// 原生层闸门：严格模式下，高危动作必须有一次近期密码验证。
/// 前端逐项弹密码框是体验层，这一层是防止绕过 UI 直接调 DLL。
pub(crate) fn require_admin(action: &str) -> Result<(), String> {
    if !strict_active() {
        return Ok(());
    }
    if crate::util::now_secs() > AUTH_UNTIL.load(Ordering::SeqCst) {
        return Err(format!("严格模式：执行「{action}」前需要先验证密码"));
    }
    // 授权一次只能用一次；动作开始前就核销，防止同一个窗口连续调多个接口。
    AUTH_UNTIL.store(0, Ordering::SeqCst);
    Ok(())
}

// ================= 安全策略设置 =================

/// 一次性返回所有安全相关配置，前端只调一次
#[no_mangle]
pub extern "C" fn security_settings(buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        let cfg = load_config();
        let g = |k: &str, d: Value| cfg.get(k).cloned().unwrap_or(d);
        ok(
            buf,
            len,
            "安全设置",
            json!({
                "pwd_enabled": pwd_enabled(),
                "pwd_has": read_pwd().is_some(),
                "clean_interval_min": g("clean_interval_min", json!(0)),
                "scan_interval_min": g("scan_interval_min", json!(0)),
                "idle_only": g("idle_only", json!(true)),
                "virus_action": g("virus_action", json!("ask")),      // auto / ask / record
                "silent_update": g("silent_update", json!(true)),
                "scan_full_speed": g("scan_full_speed", json!(true)),
                "strict_mode": g("strict_mode", json!(true)),
                "trust_dir": g("trust_dir", json!([])),
                "autostart_enabled": g("autostart_enabled", json!(false)),
                "bg_last_clean": g("bg_last_clean", json!(0)),
                "bg_last_scan": g("bg_last_scan", json!(0)),
                "bg_running": json!(BG_RUNNING.load(Ordering::SeqCst))
            }),
        )
    })
}

/// 写一项安全配置
#[no_mangle]
pub extern "C" fn security_set(
    key: *const c_char,
    value: *const c_char,
    buf: *mut u8,
    len: usize,
) -> i32 {
    crate::ffi_guard!(buf, len, {
        let (Some(k), Some(v)) = (cstr(key), cstr(value)) else {
            return fail(buf, len, -1, "参数为空");
        };
        if v.len() > 4096 {
            return fail(buf, len, -1, "配置值过长");
        }
        let parsed = serde_json::from_str::<Value>(&v).unwrap_or(Value::String(v.clone()));
        let valid = match k.as_str() {
            "clean_interval_min" | "scan_interval_min" => parsed
                .as_u64()
                .map(|m| m == 0 || (5..=10_080).contains(&m))
                .unwrap_or(false),
            "idle_only" | "silent_update" | "autostart_enabled" | "scan_full_speed"
            | "strict_mode" => parsed.is_boolean(),
            "virus_action" => matches!(parsed.as_str(), Some("auto" | "ask" | "record")),
            "trust_dir" => parsed.is_array(),
            _ => false,
        };
        if !valid {
            return fail(buf, len, -1, "不支持的配置项或值不合法");
        }
        // 严格模式下，任何安全设置都必须在近期验过密码；
        // 这样绕过 UI 直接调 DLL 也改不了查杀频率、病毒处理方式、白名单目录等。
        // 打开严格模式本身在关闭状态下不拦，因为那只会让防护更强。
        if let Err(e) = require_admin("修改安全设置") {
            return fail(buf, len, -5, &e);
        }
        let mut cfg = load_config();
        if let Value::Object(ref mut m) = cfg {
            m.insert(k.clone(), parsed);
        }
        save_config(&cfg);
        ok(buf, len, "已保存", json!({"key": k}))
    })
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
    crate::ffi_guard!(buf, len, {
        ok(buf, len, "空闲状态", json!({"idle": is_idle()}))
    })
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
        let clean_min = cfg
            .get("clean_interval_min")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);
        let scan_min = cfg
            .get("scan_interval_min")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);
        let idle_only = cfg
            .get("idle_only")
            .and_then(|v| v.as_bool())
            .unwrap_or(true);
        let now = crate::util::now_secs();

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
            let last = cfg
                .get("bg_last_clean")
                .and_then(|v| v.as_u64())
                .unwrap_or(0);
            if now.saturating_sub(last) >= clean_min * 60 {
                if strict_active() {
                    // 严格模式：后台自动清理会删文件，不能绕过密码确认。
                    if let Value::Object(ref mut m) = cfg2 {
                        m.insert("bg_last_clean".into(), json!(now));
                        m.insert("bg_last_freed".into(), json!(0));
                        m.insert("bg_last_deleted".into(), json!(0));
                    }
                    changed = true;
                    crate::bg_log(&format!("[{now}] 严格模式已开启，后台自动清理已跳过"));
                } else {
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
        }

        // 查杀到点
        if scan_min > 0 {
            let last = cfg
                .get("bg_last_scan")
                .and_then(|v| v.as_u64())
                .unwrap_or(0);
            if now.saturating_sub(last) >= scan_min * 60 {
                let found = crate::scan_common_dirs_quiet(!strict_active());
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
    crate::ffi_guard!(buf, len, {
        if BG_RUNNING.swap(true, Ordering::SeqCst) {
            return ok(buf, len, "后台任务已在运行", json!({"running": true}));
        }
        std::thread::spawn(bg_loop);
        ok(buf, len, "后台任务已启动", json!({"running": true}))
    })
}

/// 停止后台任务
#[no_mangle]
pub extern "C" fn bg_stop(buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        BG_RUNNING.store(false, Ordering::SeqCst);
        ok(buf, len, "后台任务已停止", json!({"running": false}))
    })
}

/// 后台状态 + 最近一次结果
#[no_mangle]
pub extern "C" fn bg_status(buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
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
    })
}

/// 立即跑一轮（不管到没到点）
#[no_mangle]
pub extern "C" fn bg_run_once(buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        if let Err(e) = require_admin("立即执行一轮") {
            return fail(buf, len, -5, &e);
        }
        let (freed, deleted) = crate::clean_all_quiet();
        let found = crate::scan_common_dirs_quiet(true);
        let now = crate::util::now_secs();
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
    })
}
