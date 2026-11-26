//! 子进程统一入口：一律隐藏控制台窗口
//!
//! 背景：本程序是 Windows GUI 应用（windows_subsystem = "windows"）。
//! 这种进程调 `std::process::Command::new("powershell")` / `reg` / `taskkill` 时，
//! 系统默认会给子进程分配一个新的控制台窗口 —— 用户看到的就是
//! 「启动瞬间蹦出好几个黑色 CMD 框，还没出字就自己关掉」。
//!
//! 修法只有一条：给每个子进程加 CREATE_NO_WINDOW 创建标志。
//! 33 处调用散在 8 个文件里，以前只有 runtime.rs 一处加了，
//! 所以这里收成一个 `cmd()` 入口，全项目统一走它。

use std::process::Command;

#[cfg(windows)]
pub const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// 创建子进程，Windows 下强制不弹控制台窗口
pub fn cmd<S: AsRef<std::ffi::OsStr>>(program: S) -> Command {
    #[allow(unused_mut)]
    let mut c = Command::new(program);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(CREATE_NO_WINDOW);
    }
    c
}

/// PowerShell 统一入口：参数组合只在这里写一次
pub fn ps(script: &str) -> Command {
    let mut c = cmd("powershell");
    c.args(["-NoProfile", "-NonInteractive", "-Command", script]);
    c
}

/// 跑一段 PowerShell 并解析 JSON；脚本自己输出 __ERR__ 开头表示失败
pub fn ps_json(script: &str) -> Result<serde_json::Value, String> {
    let o = ps(script)
        .output()
        .map_err(|e| format!("调用 PowerShell 失败: {e}"))?;
    let text = String::from_utf8_lossy(&o.stdout).trim().to_string();
    if let Some(msg) = text.strip_prefix("__ERR__") {
        return Err(format!("命令执行失败:{msg}"));
    }
    if text.is_empty() {
        return Err("命令没有输出".into());
    }
    serde_json::from_str(&text).map_err(|e| format!("解析失败: {e}"))
}
