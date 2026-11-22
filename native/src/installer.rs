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
        } else {
            // 删不掉的常见原因：只读/隐藏属性、被杀软或索引服务瞬时占用。
            // 先直接删，失败就清属性再删一次，别一声不响地漏掉。
            if fs::remove_file(&p).is_ok() {
                *removed += 1;
            } else {
                let _ = crate::proc::cmd("attrib")
                    .args(["-R", "-H", "-S", &p.to_string_lossy()])
                    .output();
                if fs::remove_file(&p).is_ok() {
                    *removed += 1;
                }
            }
        }
    }
    let _ = fs::remove_dir(path);
}

/// 桌面目录候选：`PUBLIC` 环境变量有时拿不到（外壳进程沙箱化），
/// 之前只认 PUBLIC，拿不到就静默不建 → 用户装完桌面没图标。这里多给几条兜底。
fn desktop_dirs() -> Vec<std::path::PathBuf> {
    let mut v: Vec<std::path::PathBuf> = Vec::new();
    if let Ok(p) = std::env::var("PUBLIC") {
        if !p.trim().is_empty() {
            v.push(std::path::PathBuf::from(p));
        }
    }
    if let Ok(sd) = std::env::var("SystemDrive") {
        if !sd.trim().is_empty() {
            v.push(std::path::PathBuf::from(format!("{sd}\\Users\\Public")));
        }
    }
    v.push(std::path::PathBuf::from("C:\\Users\\Public"));
    if let Ok(up) = std::env::var("USERPROFILE") {
        if !up.trim().is_empty() {
            v.push(std::path::PathBuf::from(format!("{up}\\Desktop")));
        }
    }
    v
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

/// 同一份旧卸载键落在 HKLM 下的版本（管理员身份安装时写的是这里）
const LEGACY_KEY_HKLM: &str =
    r"HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\{8E2C1A44-9F3B-4C71-8A55-2E6D7B4C1F90}_is1";

/// 删一个注册表键；`value` 有值时只删这个值，没有时整键连子键一起删
fn reg_del(key: &str, value: Option<&str>) {
    let mut c = crate::proc::cmd("reg");
    c.arg("delete").arg(key);
    if let Some(v) = value {
        c.args(["/v", v]);
    }
    c.arg("/f");
    let _ = c.output();
}

/// 把所有可能被写过的注册表位置**全部**清一遍
///
/// 之前卸载只删了 `Run\QWGuard` 和 `Uninstall\QWGuard` 两处，剩下三处没动：
///   ① Inno 时期写的 `Uninstall\{8E2C1A44…}_is1`（HKCU 那份）
///   ② 同一个 AppId 在 HKLM 下的那份（旧版按管理员装时写的是这里）
///   ③ `StartupApproved\Run` 里的 QWGuard —— Windows 记录「自启动已被批准」的开关，
///      不删的话任务管理器「启动」页会留一条没有主的孤儿条目
/// 顺带把 App Paths 和 `HKCU\Software\QWGuard` 也扫掉，宁可多删不可漏删。
fn purge_registry() {
    const RUN: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
    const RUN_APPROVED: &str =
        r"HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    const UNINST_HKCU: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\QWGuard";
    const UNINST_HKLM: &str = r"HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\QWGuard";
    const IS1: &str = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\{8E2C1A44-9F3B-4C71-8A55-2E6D7B4C1F90}_is1";
    const APP_PATH: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\QWGuard.exe";

    reg_del(RUN, Some("QWGuard"));
    reg_del(RUN_APPROVED, Some("QWGuard"));
    reg_del(UNINST_HKCU, None);
    reg_del(UNINST_HKLM, None);
    reg_del(&format!(r"HKCU\{IS1}"), None);
    reg_del(&format!(r"HKLM\{IS1}"), None);
    reg_del(
        r"HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{8E2C1A44-9F3B-4C71-8A55-2E6D7B4C1F90}_is1",
        None,
    );
    reg_del(APP_PATH, None);
    reg_del(r"HKCU\Software\QWGuard", None);
    reg_del(r"HKLM\Software\QWGuard", None);
    reg_del(r"HKLM\Software\WOW6432Node\QWGuard", None);
}

/// 装新版之前先把旧版的**安装目录**清掉，但绝不动用户数据
///
/// 关键：不能调旧版的 `unins000.exe`。旧 Inno 脚本的 [UninstallDelete] 里有
/// `{userappdata}\QWGuard`，而新版配置目录正好也是 `%APPDATA%\QWGuard`
/// （见 ext::cfg_dir），跑一次卸载器就会把白名单 / 隔离区 / 全部设置清空。
/// 所以这里只做两件事：删安装目录、删旧注册表键，配置目录一个字节都不碰。
fn cleanup_legacy() -> Option<String> {
    // 旧版可能落在 HKCU（当前用户装）也可能落在 HKLM（管理员装），两个都要查，
    // 只查 HKCU 的话，用管理员身份装过旧版的人这里永远查不到，目录就一直赖着
    let mut dir: Option<String> = None;
    for key in [LEGACY_KEY, LEGACY_KEY_HKLM] {
        let Some(out) = crate::proc::cmd("reg")
            .args(["query", key, "/v", "InstallLocation"])
            .output()
            .ok()
        else {
            continue;
        };
        if !out.status.success() {
            continue;
        }
        let text = String::from_utf8_lossy(&out.stdout);
        if let Some(d) = text
            .lines()
            .find(|l| l.contains("InstallLocation"))
            .and_then(|l| l.split("REG_SZ").nth(1))
            .map(|s| s.trim().to_string())
        {
            if !d.is_empty() {
                dir = Some(d);
                break;
            }
        }
    }
    let dir = dir?;
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
    // 覆盖安装时也顺手把旧键清干净（不管 HKCU / HKLM / AppId 哪一份），
    // 不然装完控制面板会同时出现新旧两条卸载项
    purge_registry();

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
        .map_err(|e| format!("本安装程序缺少校验清单 manifest.json（{e}）"))?;
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
            return Err(format!("安装文件缺失：{p}"));
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
        Err(e) => return fail(buf, len, -4, &format!("安装文件完整性校验失败：{e}")),
    };

    let mut warnings: Vec<String> = Vec::new();

    // ② 签名校验：有签名就必须有效；没签名（自编译包）放行但记一条警告
    match signature_status(&from.join(EXE_NAME)) {
        Ok(s) if s.eq_ignore_ascii_case("Valid") => {}
        Ok(s) if s.eq_ignore_ascii_case("NotSigned") || s.eq_ignore_ascii_case("Unknown") => {
            warnings.push("本安装程序未做数字签名（自编译版本），已跳过签名验证".into());
        }
        Ok(s) => {
            return fail(
                buf,
                len,
                -4,
                &format!("数字签名校验失败（状态 {s}）：安装文件可能被篡改"),
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
        let mut okd = false;
        let mut last_err = String::new();
        for dir in desktop_dirs() {
            if !dir.exists() {
                continue;
            }
            let lnk = dir.join(format!("{APP_NAME}.lnk"));
            match make_shortcut(&lnk, &exe, &to, APP_NAME) {
                Ok(_) => {
                    okd = true;
                    break;
                }
                Err(e) => last_err = e,
            }
        }
        if !okd {
            warnings.push(format!(
                "桌面快捷方式没建成（{}）",
                if last_err.is_empty() { "没有可写的桌面目录".to_string() } else { last_err }
            ));
        }
    }

    // 自启动
    if autostart != 0 {
        let run = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
        // 先删掉老版本登记的英文项，避免注册表里同时挂两条
        let _ = crate::proc::cmd("reg")
            .args(["delete", run, "/v", "QWGuard", "/f"])
            .output();
        let _ = crate::proc::cmd("reg")
            .args([
                "add",
                run,
                "/v",
                "QW安全电脑管家",
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
pub extern "C" fn uninstall_run(
    app_dir: *const c_char,
    keep_config: i32,
    pwd: *const c_char,
    buf: *mut u8,
    len: usize,
) -> i32 {
    let Some(dir) = cstr(app_dir) else {
        return fail(buf, len, -1, "参数为空");
    };
    if !cfg!(windows) {
        return fail(buf, len, -3, "卸载流程仅支持 Windows");
    }
    // 密码保护一旦开启，控制面板 / 命令行 / 第三方卸载器调进来都要过这道闸。
    let pass = cstr(pwd).unwrap_or_default();
    if let Err(msg) = crate::security::check_uninstall_pwd(&pass) {
        return fail(buf, len, -5, msg);
    }
    let app = PathBuf::from(&dir);

    // 先关掉自己，不然文件被占用删不掉
    let _ = crate::proc::cmd("taskkill")
        .args(["/F", "/IM", EXE_NAME])
        .output();
    std::thread::sleep(std::time::Duration::from_millis(800));

    let mut removed = 0u64;
    // 反复三次：刚 taskkill 完，Explorer / Defender / 索引服务可能还捏着句柄
    for _ in 0..3 {
        if !app.exists() {
            break;
        }
        remove_tree(&app, &mut removed);
        if app.exists() {
            std::thread::sleep(std::time::Duration::from_millis(350));
        }
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
    for dir in desktop_dirs() {
        let _ = fs::remove_file(dir.join(format!("{APP_NAME}.lnk")));
    }

    // 注册表：一次清干净。之前只删两处，Inno 时期的 AppId 键、
    // HKLM 那份、StartupApproved 记录全都留在了系统里。
    purge_registry();

    // 收尾：卸载器自己正在运行，exe 和目录会被文件锁占住删不掉，
    // 于是「卸载完成」之后安装目录还会剩下一个 Uninstall.exe + 空壳目录。
    // 交给系统在进程退出后再补一刀：等 2 秒 → 删自己 → 删目录。
    // 不带这步，用户回控制面板看是干净的，去 D:\ 一看目录还在。
    // 三次还删不掉的（被杀软占着、或目录 ACL 只有管理员能改），
    // 登记到下次登录时再清，别留一个空壳目录让用户以为没卸干净。
    if app.exists() {
        let line = format!("cmd /c rmdir /s /q \"{}\"", app.display());
        let _ = crate::proc::cmd("reg")
            .args([
                "add",
                r"HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce",
                "/v",
                "QWGuardCleanup",
                "/t",
                "REG_SZ",
                "/d",
                &line,
                "/f",
            ])
            .output();
    }
    if app.exists() {
        let self_exe = std::env::current_exe().unwrap_or_default();
        let line = format!(
            r#"ping -n 3 127.0.0.1 >nul & del /f /q "{}" & rmdir /s /q "{}""#,
            self_exe.display(),
            app.display()
        );
        let _ = crate::proc::cmd("cmd").args(["/c", line.as_str()]).output();
    }

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
