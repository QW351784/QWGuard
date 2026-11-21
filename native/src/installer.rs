//! 安装 / 卸载底层：复制文件、建快捷方式、写注册表、清残留
//!
//! 设计：安装器和主程序是同一个二进制（同一套 Flutter 引擎），
//! 靠参数区分 `--setup` / `--uninstall`，不额外多打一份引擎，省体积。

use serde_json::json;
use std::ffi::c_char;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::ext::cfg_dir;
use crate::{cstr, fail, ok};

const APP_NAME: &str = "QW 安全电脑管家";
const EXE_NAME: &str = "system_toolbox.exe";

fn copy_tree(src: &Path, dst: &Path, copied: &mut u64, bytes: &mut u64) -> Result<(), String> {
    fs::create_dir_all(dst).map_err(|e| format!("创建目录失败 {}: {e}", dst.display()))?;
    let rd = fs::read_dir(src).map_err(|e| format!("读取失败 {}: {e}", src.display()))?;
    for e in rd.flatten() {
        let p = e.path();
        let Some(name) = p.file_name().map(|n| n.to_owned()) else {
            continue;
        };
        // 别把自己拷进自己
        if p == dst {
            continue;
        }
        let target = dst.join(&name);
        let Ok(meta) = fs::symlink_metadata(&p) else {
            continue;
        };
        if meta.file_type().is_symlink() {
            continue;
        }
        if meta.is_dir() {
            copy_tree(&p, &target, copied, bytes)?;
        } else if meta.is_file() {
            fs::copy(&p, &target).map_err(|e| format!("复制失败 {}: {e}", p.display()))?;
            *copied += 1;
            *bytes += meta.len();
        }
    }
    Ok(())
}

fn remove_tree(path: &Path, removed: &mut u64) {
    let Ok(rd) = fs::read_dir(path) else {
        let _ = fs::remove_file(path);
        return;
    };
    for e in rd.flatten() {
        let p = e.path();
        let Ok(meta) = fs::symlink_metadata(&p) else {
            continue;
        };
        if meta.is_dir() {
            remove_tree(&p, removed);
        } else if fs::remove_file(&p).is_ok() {
            *removed += 1;
        }
    }
    let _ = fs::remove_dir(path);
}

/// PowerShell 建快捷方式（不依赖额外 crate）
fn make_shortcut(lnk: &Path, target: &Path, workdir: &Path, desc: &str) -> Result<(), String> {
    let lnk_s = lnk.to_string_lossy().replace('\'', "''");
    let tgt_s = target.to_string_lossy().replace('\'', "''");
    let wd_s = workdir.to_string_lossy().replace('\'', "''");
    let script = format!(
        "$ws=New-Object -ComObject WScript.Shell;\
         $s=$ws.CreateShortcut('{lnk_s}');\
         $s.TargetPath='{tgt_s}';\
         $s.WorkingDirectory='{wd_s}';\
         $s.IconLocation='{tgt_s},0';\
         $s.Description='{desc}';\
         $s.Save()"
    );
    match Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .output()
    {
        Ok(o) if o.status.success() => Ok(()),
        Ok(o) => Err(String::from_utf8_lossy(&o.stderr).trim().to_string()),
        Err(e) => Err(e.to_string()),
    }
}

/// 安装：把 payload 目录整体复制到目标目录，按开关建快捷方式、自启动、卸载注册表项
#[no_mangle]
pub extern "C" fn install_run(
    src: *const c_char,
    dst: *const c_char,
    desktop_icon: i32,
    autostart: i32,
    buf: *mut u8,
    len: usize,
) -> i32 {
    let (Some(src), Some(dst)) = (cstr(src), cstr(dst)) else {
        return fail(buf, len, -1, "参数为空");
    };
    let from = PathBuf::from(&src);
    let to = PathBuf::from(&dst);
    if !from.is_dir() {
        return fail(buf, len, -3, "安装源目录不存在");
    }
    if !cfg!(windows) {
        return fail(buf, len, -3, "安装流程仅支持 Windows");
    }

    let mut copied = 0u64;
    let mut bytes = 0u64;
    if let Err(e) = copy_tree(&from, &to, &mut copied, &mut bytes) {
        return fail(buf, len, -3, &e);
    }

    let exe = to.join(EXE_NAME);
    let mut warnings: Vec<String> = Vec::new();

    // 开始菜单
    if let Ok(appdata) = std::env::var("APPDATA") {
        let start = Path::new(&appdata)
            .join("Microsoft\\Windows\\Start Menu\\Programs")
            .join(APP_NAME);
        let _ = fs::create_dir_all(&start);
        let lnk = start.join(format!("{APP_NAME}.lnk"));
        if let Err(e) = make_shortcut(&lnk, &exe, &to, APP_NAME) {
            warnings.push(format!("开始菜单快捷方式失败: {e}"));
        }
    }

    // 桌面
    if desktop_icon != 0 {
        if let Ok(pub_dir) = std::env::var("PUBLIC") {
            let lnk = Path::new(&pub_dir).join(format!("{APP_NAME}.lnk"));
            if let Err(e) = make_shortcut(&lnk, &exe, &to, APP_NAME) {
                warnings.push(format!("桌面快捷方式失败: {e}"));
            }
        }
    }

    // 自启动
    if autostart != 0 {
        let run = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
        let _ = Command::new("reg")
            .args([
                "add",
                run,
                "/v",
                "QWGuard",
                "/t",
                "REG_SZ",
                "/d",
                &exe.to_string_lossy(),
                "/f",
            ])
            .output();
    }

    // 控制面板的卸载入口
    let uninst_key = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\QWGuard";
    let uninst_cmd = format!("\"{}\" --uninstall", exe.to_string_lossy());
    for (name, value) in [
        ("DisplayName", APP_NAME.to_string()),
        ("DisplayVersion", "1.0.0".to_string()),
        ("DisplayIcon", exe.to_string_lossy().to_string()),
        ("InstallLocation", to.to_string_lossy().to_string()),
        ("UninstallString", uninst_cmd),
        ("Publisher", "QW".to_string()),
    ] {
        let _ = Command::new("reg")
            .args(["add", uninst_key, "/v", name, "/t", "REG_SZ", "/d", &value, "/f"])
            .output();
    }
    let _ = Command::new("reg")
        .args([
            "add",
            uninst_key,
            "/v",
            "NoModify",
            "/t",
            "REG_DWORD",
            "/d",
            "1",
            "/f",
        ])
        .output();

    ok(
        buf,
        len,
        "安装完成",
        json!({
            "path": to.to_string_lossy(),
            "copied": copied,
            "bytes": bytes,
            "warnings": warnings
        }),
    )
}

/// 卸载：先杀进程，再删目录、配置、快捷方式、注册表
#[no_mangle]
pub extern "C" fn uninstall_run(app_dir: *const c_char, keep_config: i32, buf: *mut u8, len: usize) -> i32 {
    let Some(dir) = cstr(app_dir) else {
        return fail(buf, len, -1, "参数为空");
    };
    if !cfg!(windows) {
        return fail(buf, len, -3, "卸载流程仅支持 Windows");
    }
    let app = PathBuf::from(&dir);

    // 先关掉自己，不然文件被占用删不掉
    let _ = Command::new("taskkill")
        .args(["/F", "/IM", EXE_NAME])
        .output();
    std::thread::sleep(std::time::Duration::from_millis(800));

    let mut removed = 0u64;
    if app.exists() {
        remove_tree(&app, &mut removed);
    }

    // 配置目录
    if keep_config == 0 {
        let cfg = cfg_dir();
        if cfg.exists() {
            remove_tree(&cfg, &mut removed);
        }
    }

    // 快捷方式
    if let Ok(appdata) = std::env::var("APPDATA") {
        let start = Path::new(&appdata)
            .join("Microsoft\\Windows\\Start Menu\\Programs")
            .join(APP_NAME);
        let _ = fs::remove_dir_all(&start);
    }
    if let Ok(pub_dir) = std::env::var("PUBLIC") {
        let _ = fs::remove_file(Path::new(&pub_dir).join(format!("{APP_NAME}.lnk")));
    }

    // 注册表
    let _ = Command::new("reg")
        .args([
            "delete",
            r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run",
            "/v",
            "QWGuard",
            "/f",
        ])
        .output();
    let _ = Command::new("reg")
        .args([
            "delete",
            r"HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\QWGuard",
            "/f",
        ])
        .output();

    ok(buf, len, "卸载完成", json!({"removed_files": removed, "kept_config": keep_config != 0}))
}

/// 系统深浅色：Windows 读注册表，其它平台默认浅色
#[no_mangle]
pub extern "C" fn system_theme(buf: *mut u8, len: usize) -> i32 {
    let mut dark = false;
    if cfg!(windows) {
        if let Ok(o) = Command::new("reg")
            .args([
                "query",
                r"HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "/v",
                "AppsUseLightTheme",
            ])
            .output()
        {
            let text = String::from_utf8_lossy(&o.stdout);
            if let Some(pos) = text.find("REG_DWORD") {
                let tail = text[pos..].trim();
                if let Some(v) = tail.split_whitespace().nth(1) {
                    dark = v.trim() == "0x0";
                }
            }
        }
    }
    ok(buf, len, "系统主题", json!({"dark": dark}))
}

/// 安装器自检：确认 payload 完整（缺 dll 或 data 就报错，不让人装半个软件）
#[no_mangle]
pub extern "C" fn install_precheck(src: *const c_char, buf: *mut u8, len: usize) -> i32 {
    let Some(src) = cstr(src) else {
        return fail(buf, len, -1, "参数为空");
    };
    let root = PathBuf::from(&src);
    let mut missing: Vec<String> = Vec::new();
    for need in [EXE_NAME, "flutter_windows.dll", "data"] {
        if !root.join(need).exists() {
            missing.push(need.to_string());
        }
    }
    ok(
        buf,
        len,
        if missing.is_empty() { "环境完整" } else { "环境不完整" },
        json!({"ok": missing.is_empty(), "missing": missing, "src": src}),
    )
}
