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
// 必须跟 CI 改名后的实际文件名一致：flutter 项目名是 system_toolbox，
// 但构建脚本会把它改名成 QWGuard.exe，这里再写旧名字就会导致
// 快捷方式 / 卸载项 / taskkill 全部指向不存在的文件，安装看起来“装了个空壳”。
const EXE_NAME: &str = "QWGuard.exe";
// 卸载走独立的卸载器 exe（同一份二进制按文件名分流进卸载向导）
const UNINST_EXE: &str = "QWGuard-Uninstall.exe";

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
    match crate::proc::cmd("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .output()
    {
        Ok(o) if o.status.success() => Ok(()),
        Ok(o) => Err(String::from_utf8_lossy(&o.stderr).trim().to_string()),
        Err(e) => Err(e.to_string()),
    }
}

/// 旧版（Inno 外壳）写的卸载键：AppId + `_is1`
/// 跟新版自己写的 `Uninstall\QWGuard` 是两个完全不同的键，
/// 所以不主动清就会出现「控制面板两条同名卸载项」。
const LEGACY_KEY: &str =
    r"HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\{8E2C1A44-9F3B-4C71-8A55-2E6D7B4C1F90}_is1";

/// 装新版之前先把旧版的**安装目录**清掉，但绝不动用户数据
///
/// 关键：不能调旧版的 `unins000.exe`。旧 Inno 脚本的 [UninstallDelete] 里有
/// `{userappdata}\QWGuard`，而新版配置目录正好也是 `%APPDATA%\QWGuard`
/// （见 ext::cfg_dir），跑一次卸载器就会把白名单 / 隔离区 / 全部设置清空。
/// 所以这里只做两件事：删安装目录、删旧注册表键，配置目录一个字节都不碰。
fn cleanup_legacy() -> Option<String> {
    let out = crate::proc::cmd("reg")
        .args(["query", LEGACY_KEY, "/v", "InstallLocation"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let dir = text
        .lines()
        .find(|l| l.contains("InstallLocation"))
        .and_then(|l| l.split("REG_SZ").nth(1))
        .map(|s| s.trim().to_string())?;
    if dir.is_empty() {
        return None;
    }
    let old = PathBuf::from(&dir);

    // 旧安装目录里的进程要先停，否则文件被占用删不掉
    let _ = crate::proc::cmd("taskkill")
        .args(["/F", "/IM", EXE_NAME])
        .output();
    std::thread::sleep(std::time::Duration::from_millis(400));

    let mut removed = 0u64;
    if old.exists() {
        remove_tree(&old, &mut removed);
    }
    let _ = crate::proc::cmd("reg")
        .args(["delete", LEGACY_KEY, "/f"])
        .output();

    Some(format!("已替换旧版安装目录：{dir}（用户数据保留）"))
}

/// SHA-256 十六进制小写
fn hex_sha256(data: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(data);
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

/// 校验待安装目录的完整性：每个文件都必须和 `manifest.json` 里的 SHA-256 对上
///
/// 目的不是防外贼，是防「传输或解压过程把文件弄坏了还照样装进去」——
/// 装完一个坏 dll，程序一起就崩，用户根本不知道该怪谁。
fn verify_manifest(dir: &Path) -> Result<usize, String> {
    let mf = dir.join("manifest.json");
    let text = fs::read_to_string(&mf)
        .map_err(|e| format!("安装包缺少校验清单 manifest.json（{e}）"))?;
    let v: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("校验清单格式损坏：{e}"))?;
    let files = v
        .get("files")
        .and_then(|f| f.as_array())
        .ok_or_else(|| "校验清单里没有 files 列表".to_string())?;
    if files.is_empty() {
        return Err("校验清单是空的".to_string());
    }

    let mut checked = 0usize;
    for item in files {
        let Some(p) = item.get("path").and_then(|x| x.as_str()) else {
            continue;
        };
        let Some(want) = item.get("sha256").and_then(|x| x.as_str()) else {
            continue;
        };
        let full = dir.join(p);
        if !full.exists() {
            return Err(format!("安装包缺少文件：{p}"));
        }
        let data = fs::read(&full).map_err(|e| format!("读取 {p} 失败：{e}"))?;
        let got = hex_sha256(&data);
        if !got.eq_ignore_ascii_case(want) {
            return Err(format!("文件校验不通过：{p}\n期望 {want}\n实际 {got}"));
        }
        checked += 1;
    }
    if checked == 0 {
        return Err("校验清单里没有一条可用记录".to_string());
    }
    Ok(checked)
}

/// Authenticode 签名状态
///
/// `Valid` = 签名有效且受信任；`NotSigned` = 没签名（自编译包常态）。
/// 其它状态（哈希不匹配、证书不受信）一律当失败 —— 那说明文件被动过。
#[cfg(windows)]
fn signature_status(path: &Path) -> Result<String, String> {
    let p = path.to_string_lossy().replace('\'', "''");
    let script = format!("(Get-AuthenticodeSignature -LiteralPath '{p}').Status");
    let o = crate::proc::cmd("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .output()
        .map_err(|e| format!("签名检测无法执行：{e}"))?;
    let out = String::from_utf8_lossy(&o.stdout).trim().to_string();
    if out.is_empty() {
        return Ok("Unknown".into());
    }
    Ok(out)
}

#[cfg(not(windows))]
fn signature_status(_path: &Path) -> Result<String, String> {
    Ok("NotSigned".into())
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

    // ① 完整性校验：manifest.json 里每个文件的 SHA-256 必须对上
    let verified = match verify_manifest(&from) {
        Ok(n) => n,
        Err(e) => return fail(buf, len, -4, &format!("安装包完整性校验失败：{e}")),
    };

    let mut warnings: Vec<String> = Vec::new();

    // ② 签名校验：有签名就必须有效；没签名（自编译包）放行但记一条警告
    match signature_status(&from.join(EXE_NAME)) {
        Ok(s) if s.eq_ignore_ascii_case("Valid") => {}
        Ok(s) if s.eq_ignore_ascii_case("NotSigned") || s.eq_ignore_ascii_case("Unknown") => {
            warnings.push("安装包未做数字签名（自编译版本），已跳过签名验证".into());
        }
        Ok(s) => {
            return fail(
                buf,
                len,
                -4,
                &format!("数字签名校验失败（状态 {s}）：安装包可能被篡改"),
            );
        }
        Err(e) => warnings.push(format!("签名检测未执行：{e}")),
    }

    // ③ 覆盖安装：目标目录已经有旧版本时，先停掉正在跑的进程再原地覆盖。
    //    配置目录在 %APPDATA%\QWGuard，不在安装目录里，所以换文件不会丢数据。
    if to.join(EXE_NAME).exists() {
        let _ = crate::proc::cmd("taskkill")
            .args(["/F", "/IM", EXE_NAME])
            .output();
        std::thread::sleep(std::time::Duration::from_millis(600));
        warnings.push("检测到已有安装，执行覆盖升级（用户数据保留）".into());
    }

    // 复制之前先清旧版安装目录：旧版目录名和新版不同，不清就是两套并存
    let legacy = cleanup_legacy();

    let mut copied = 0u64;
    let mut bytes = 0u64;
    if let Err(e) = copy_tree(&from, &to, &mut copied, &mut bytes) {
        return fail(buf, len, -3, &e);
    }

    let exe = to.join(EXE_NAME);
    if let Some(l) = legacy {
        warnings.push(l);
    }

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
        let _ = crate::proc::cmd("reg")
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

    // 控制面板的卸载入口：优先指向独立卸载器，退回主程序 --uninstall
    let uninst_key = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\QWGuard";
    let uninst_exe = to.join(UNINST_EXE);
    let uninst_cmd = if uninst_exe.exists() {
        format!("\"{}\"", uninst_exe.to_string_lossy())
    } else {
        format!("\"{}\" --uninstall", exe.to_string_lossy())
    };
    for (name, value) in [
        ("DisplayName", APP_NAME.to_string()),
        ("DisplayVersion", "1.0".to_string()),
        ("DisplayIcon", exe.to_string_lossy().to_string()),
        ("InstallLocation", to.to_string_lossy().to_string()),
        ("UninstallString", uninst_cmd),
        ("Publisher", "QW".to_string()),
    ] {
        let _ = crate::proc::cmd("reg")
            .args(["add", uninst_key, "/v", name, "/t", "REG_SZ", "/d", &value, "/f"])
            .output();
    }
    let _ = crate::proc::cmd("reg")
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
            "verified": verified,
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
    let _ = crate::proc::cmd("taskkill")
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
    let _ = crate::proc::cmd("reg")
        .args([
            "delete",
            r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run",
            "/v",
            "QWGuard",
            "/f",
        ])
        .output();
    let _ = crate::proc::cmd("reg")
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
        if let Ok(o) = crate::proc::cmd("reg")
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
    // manifest.json 是完整性校验的依据，缺了就没法验证，提前在前端就报出来
    for need in [EXE_NAME, "flutter_windows.dll", "data", "manifest.json"] {
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
