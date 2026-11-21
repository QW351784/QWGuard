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
