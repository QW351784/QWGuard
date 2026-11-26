//! 工具箱里的几把小工具：小箭头开关、文件后缀开关、文件粉碎、环境自检
//!
//! 几个约定：
//! - 小箭头和后缀都是改注册表，天然可逆，再点一次就还原
//! - 粉碎机走「先解除占用 → 三遍覆写 → 删文件」，覆写顺序 0x00 / 0xFF / 伪随机
//! - 粉碎机不碰自己的文件：安装目录、配置目录、隔离库一律拒绝

use serde_json::json;
use std::ffi::c_char;
use std::fs;
use std::io::{Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use crate::ext::cfg_dir;
use crate::{cstr, fail, ok};

const SHELL_ICONS: &str = r"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons";
const EXPLORER_ADV: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced";

fn refresh_explorer() {
    // 让资源管理器重新读注册表，不然要等下次登录
    let _ = crate::proc::cmd("ie4uinit.exe").arg("-show").output();
    let _ = crate::proc::cmd("taskkill")
        .args(["/F", "/IM", "explorer.exe"])
        .output();
}

// ================= 快捷方式小箭头 =================

/// `on = true` 去掉小箭头，`false` 恢复系统默认
#[no_mangle]
pub extern "C" fn shortcut_arrow(on: i32, buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        if let Err(e) = crate::security::require_admin("修改快捷方式小箭头") {
            return fail(buf, len, -5, &e);
        }
        if !cfg!(windows) {
            return fail(buf, len, -3, "仅支持 Windows");
        }
        let ok_flag = if on != 0 {
            // 值 29 是快捷方式角标，指向一个空图标就等于把它抹掉
            crate::proc::cmd("reg")
                .args([
                    "add",
                    SHELL_ICONS,
                    "/v",
                    "29",
                    "/t",
                    "REG_SZ",
                    "/d",
                    r"%SystemRoot%\System32\shell32.dll,50",
                    "/f",
                ])
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false)
        } else {
            crate::proc::cmd("reg")
                .args(["delete", SHELL_ICONS, "/v", "29", "/f"])
                .output()
                .map(|o| o.status.success())
                .unwrap_or(true)
        };

        if !ok_flag {
            return fail(buf, len, -3, "注册表写入失败（需要管理员权限）");
        }
        refresh_explorer();
        ok(
            buf,
            len,
            if on != 0 {
                "小箭头已去掉"
            } else {
                "小箭头已恢复"
            },
            json!({"removed": on != 0, "reversible": true}),
        )
    })
}

// ================= 文件后缀显示 =================

/// `show = true` 显示所有扩展名，`false` 恢复隐藏
#[no_mangle]
pub extern "C" fn file_ext_show(show: i32, buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        if let Err(e) = crate::security::require_admin("修改文件后缀显示") {
            return fail(buf, len, -5, &e);
        }
        if !cfg!(windows) {
            return fail(buf, len, -3, "仅支持 Windows");
        }
        let v = if show != 0 { "0" } else { "1" };
        let done = crate::proc::cmd("reg")
            .args([
                "add",
                EXPLORER_ADV,
                "/v",
                "HideFileExt",
                "/t",
                "REG_DWORD",
                "/d",
                v,
                "/f",
            ])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        if !done {
            return fail(buf, len, -3, "注册表写入失败");
        }
        refresh_explorer();
        ok(
            buf,
            len,
            if show != 0 {
                "已显示所有扩展名"
            } else {
                "已恢复隐藏扩展名"
            },
            json!({"shown": show != 0, "reversible": true}),
        )
    })
}

// ================= 文件粉碎 =================

fn is_self_file(p: &Path) -> bool {
    let c = p.to_string_lossy().to_lowercase();
    let cfg = cfg_dir().to_string_lossy().to_lowercase();
    if c.starts_with(&cfg) {
        return true;
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let d = dir.to_string_lossy().to_lowercase();
            if c.starts_with(&d) {
                return true;
            }
        }
    }
    false
}

/// 系统关键位置，禁止粉碎——防止手滑把系统删了
/// 只在入口判一次（路径数量有限），不跟着递归跑

/// 尝试解除占用：rename 探测三次，成功就说明句柄已经放开
fn try_unlock(path: &Path) -> bool {
    for _ in 0..3 {
        let tmp = path.with_extension("qwtmp");
        if fs::rename(path, &tmp).is_ok() {
            let _ = fs::rename(&tmp, path);
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(350));
    }
    false
}

fn shred_file(path: &Path, passes: u8) -> Result<u64, String> {
    let meta = fs::symlink_metadata(path).map_err(|e| format!("读不到 {}: {e}", path.display()))?;
    if !meta.is_file() {
        return Err("不是普通文件".into());
    }
    let len = meta.len();
    if len == 0 {
        let _ = fs::remove_file(path);
        return Ok(0);
    }

    let mut f = fs::OpenOptions::new()
        .write(true)
        .open(path)
        .map_err(|e| format!("打不开（可能被占用）: {e}"))?;
    let mut buf = vec![0u8; 65536];

    for pass in 0..passes {
        f.seek(SeekFrom::Start(0))
            .map_err(|e| format!("定位失败: {e}"))?;
        let mut written = 0u64;
        while written < len {
            let chunk = ((len - written) as usize).min(buf.len());
            for (i, slot) in buf.iter_mut().enumerate().take(chunk) {
                *slot = match pass {
                    0 => 0x00,
                    1 => 0xFF,
                    _ => ((written + i as u64) % 251) as u8,
                };
            }
            f.write_all(&buf[..chunk])
                .map_err(|e| format!("写入失败: {e}"))?;
            written += chunk as u64;
        }
        let _ = f.sync_all();
    }
    drop(f);
    fs::remove_file(path).map_err(|e| format!("删除失败: {e}"))?;
    Ok(len)
}

fn shred_walk(
    path: &Path,
    passes: u8,
    depth: u8,
    done: &mut u64,
    bytes: &mut u64,
    failed: &mut Vec<String>,
) {
    // 层级过深就停，防止极端目录结构把递归栈撑爆
    if depth > 64 {
        failed.push(format!("{}: 目录层级过深，已跳过", path.display()));
        return;
    }
    let Ok(meta) = fs::symlink_metadata(path) else {
        failed.push(format!("{}: 不存在", path.display()));
        return;
    };
    if meta.file_type().is_symlink() {
        return;
    }
    if meta.is_file() {
        if is_self_file(path) {
            failed.push(format!("{}: 本程序自己的文件，拒绝粉碎", path.display()));
            return;
        }
        if !try_unlock(path) {
            failed.push(format!("{}: 被占用且无法解除", path.display()));
            return;
        }
        match shred_file(path, passes) {
            Ok(n) => {
                *done += 1;
                *bytes += n;
            }
            Err(e) => failed.push(format!("{}: {e}", path.display())),
        }
        return;
    }
    if let Ok(rd) = fs::read_dir(path) {
        for e in rd.flatten() {
            shred_walk(&e.path(), passes, depth + 1, done, bytes, failed);
        }
    }
    let _ = fs::remove_dir(path);
}

/// 粉碎入口：接受 JSON 数组，元素可以是文件或目录
#[no_mangle]
pub extern "C" fn shredder_run(
    paths: *const c_char,
    passes: i32,
    dry_run: i32,
    buf: *mut u8,
    len: usize,
) -> i32 {
    crate::ffi_guard!(buf, len, {
        let Some(raw) = cstr(paths) else {
            return fail(buf, len, -1, "参数为空");
        };
        let Ok(list) = serde_json::from_str::<Vec<String>>(&raw) else {
            return fail(buf, len, -1, "路径列表解析失败");
        };
        if list.is_empty() {
            return fail(buf, len, -1, "没有选中任何文件");
        }
        if dry_run == 0 {
            if let Err(e) = crate::security::require_admin("文件粉碎") {
                return fail(buf, len, -5, &e);
            }
        }

        let p = passes.clamp(1, 7) as u8;
        let (mut done, mut bytes, mut failed) = (0u64, 0u64, Vec::new());

        for item in &list {
            let path = PathBuf::from(item);
            if crate::util::is_protected(&path) {
                failed.push(format!("{item}: 系统关键位置，禁止粉碎"));
                continue;
            }
            if dry_run != 0 {
                let Ok(meta) = fs::symlink_metadata(&path) else {
                    failed.push(format!("{item}: 不存在"));
                    continue;
                };
                if is_self_file(&path) {
                    failed.push(format!("{item}: 本程序自己的文件，拒绝粉碎"));
                    continue;
                }
                done += 1;
                bytes += if meta.is_file() { meta.len() } else { 0 };
                continue;
            }
            shred_walk(&path, p, 0, &mut done, &mut bytes, &mut failed);
        }

        ok(
            buf,
            len,
            if dry_run != 0 {
                "预演完成"
            } else {
                "粉碎完成"
            },
            json!({
                "files": done,
                "bytes": bytes,
                "passes": p,
                "failed": failed,
                "dry_run": dry_run != 0
            }),
        )
    })
}

// ================= 环境自检 =================

/// 启动时调用：确认自己在安装目录里、依赖齐全
/// 只被单独提取出去（没装本程序）时，这里会列出一堆缺失，前端据此报错
#[no_mangle]
pub extern "C" fn env_check(buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        let exe = std::env::current_exe().ok();
        let root = exe
            .as_ref()
            .and_then(|p| p.parent())
            .map(|p| p.to_path_buf());

        let mut issues: Vec<String> = Vec::new();
        let mut installed = false;

        if let Some(dir) = &root {
            for need in ["flutter_windows.dll", "data", "toolkit_native.dll"] {
                if !dir.join(need).exists() {
                    issues.push(format!("缺少 {need}"));
                }
            }
            // 装没装过，不能拿注册表说了算：
            //   · Inno 写的是 Uninstall\{GUID}_is1，跟这里的 QWGuard 永远对不上
            //   · 免安装版压根没有卸载项
            //   · 换台机器拷贝过去的、系统还原后注册表丢了的，文件其实都是齐的
            // 只要三个文件在，就说明是一份完整的程序，能跑。装没装过只影响
            // 「有没有卸载入口」，不影响能不能启动。
            installed = dir.join("toolkit_native.dll").exists() && dir.join("data").exists();
        } else {
            issues.push("拿不到自身路径".into());
        }

        ok(
            buf,
            len,
            if issues.is_empty() {
                "环境正常"
            } else {
                "环境异常"
            },
            json!({
                "ok": issues.is_empty(),
                "installed": installed,
                "root": root.map(|p| p.to_string_lossy().to_string()).unwrap_or_default(),
                "issues": issues
            }),
        )
    })
}

/// 当前是否已装（轻量版，只查注册表）
#[no_mangle]
pub extern "C" fn is_installed(buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        if !cfg!(windows) {
            return ok(buf, len, "非 Windows", json!({"installed": false}));
        }
        let installed = crate::proc::cmd("reg")
            .args([
                "query",
                r"HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\QWGuard",
            ])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        ok(buf, len, "安装状态", json!({"installed": installed}))
    })
}

/// 系统版本：判断是否达到 Windows 10 1809（内部版本 17763）
///
/// 达不到不给装、也不假装能跑，界面直接给一句人话，别让用户以为软件坏了。
#[no_mangle]
pub extern "C" fn os_version(buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        let mut build: u32 = 0;
        let mut product = String::new();

        if cfg!(windows) {
            for (key, slot) in [("CurrentBuildNumber", 0u8), ("ProductName", 1u8)] {
                let Ok(o) = crate::proc::cmd("reg")
                    .args([
                        "query",
                        r"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion",
                        "/v",
                        key,
                    ])
                    .output()
                else {
                    continue;
                };
                let text = String::from_utf8_lossy(&o.stdout).to_string();
                let Some(pos) = text.find("REG_SZ") else {
                    continue;
                };
                let rest = text[pos + 6..].trim();
                if slot == 0 {
                    build = rest
                        .split_whitespace()
                        .next()
                        .unwrap_or("0")
                        .parse()
                        .unwrap_or(0);
                } else {
                    product = rest.lines().next().unwrap_or("").trim().to_string();
                }
            }
        }

        const MIN_BUILD: u32 = 17763;
        let supported = !cfg!(windows) || build >= MIN_BUILD;
        let label = if build >= 22000 {
            "Windows 11"
        } else if build >= MIN_BUILD {
            "Windows 10"
        } else if build > 0 {
            "低于 Windows 10 1809"
        } else {
            "未知系统"
        };

        ok(
            buf,
            len,
            "系统版本",
            json!({
                "build": build,
                "product": product,
                "label": label,
                "supported": supported,
                "min_build": MIN_BUILD,
                "tip": if supported {
                    "".to_string()
                } else {
                    "本程序需要 Windows 10 1809（内部版本 17763）及以上。当前系统版本过低，装上也跑不起来，建议先在设置里更新系统。".to_string()
                }
            }),
        )
    })
}
