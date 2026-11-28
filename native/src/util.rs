//! 跨模块共用的小工具：时间戳、系统关键路径判定
//!
//! 以前这两件事在 4 个文件里各写了一份，而且 Windows 版的分段判断写错了
//! （把 RootDir 当成第一段，导致 C:\Windows 其实没被拦住）。

use std::path::{Component, Path};

pub(crate) fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// 系统关键位置：清理 / 粉碎都走这一套，避免两边判得不一样。
pub(crate) fn is_protected(p: &Path) -> bool {
    let t = p
        .to_string_lossy()
        .trim_end_matches(['\\', '/'])
        .to_lowercase();
    if matches!(
        t.as_str(),
        "c:" | "c:\\windows" | "/" | "/etc" | "/usr" | "/bin" | "/home"
    ) {
        return true;
    }
    if !cfg!(windows) {
        return false;
    }

    // 只看 Normal 段：Prefix("C:") / RootDir 都不是目录名
    let mut normals: Vec<String> = Vec::new();
    let mut first = String::new();
    for c in p.components() {
        if let Component::Normal(s) = c {
            let s = s.to_string_lossy().to_uppercase();
            if first.is_empty() {
                first = s.clone();
            }
            normals.push(s);
        }
    }
    if first.is_empty() {
        return true; // 盘根 / 空路径
    }
    let second = normals.get(1).map(String::as_str).unwrap_or("");
    // 系统目录里的「垃圾子目录」放行，其余一律拒绝：
    // 清理规则本身就会扫 Prefetch / WER，不能因为父目录叫 Windows 就全拦掉。
    let allowed_system_junk = match first.as_str() {
        "WINDOWS" => matches!(second, "TEMP" | "PREFETCH"),
        "PROGRAMDATA" => {
            normals.get(1).map(String::as_str) == Some("MICROSOFT")
                && normals.get(2).map(String::as_str) == Some("WINDOWS")
                && normals.get(3).map(String::as_str) == Some("WER")
        }
        _ => false,
    };
    if allowed_system_junk {
        return false;
    }
    let guarded = matches!(
        first.as_str(),
        "WINDOWS"
            | "PROGRAM FILES"
            | "PROGRAM FILES (X86)"
            | "PROGRAMDATA"
            | "$RECYCLE.BIN"
            | "SYSTEM VOLUME INFORMATION"
            | "BOOT"
            | "EFI"
            | "RECOVERY"
            | "PERFLOGS"
            | "ESD"
    );
    if guarded {
        return true;
    }
    // C:\Users\xxx 整层用户目录
    first == "USERS" && normals.len() <= 2
}

/// Windows 的 junction / mount point 也是 reparse point，但 `is_symlink()` 认不出来。
/// 清理和扫描都必须跳过它们，否则别人在 Temp 里放一个指向 C:\Windows 的联接点，
/// 递归删除就会穿过去。
pub(crate) fn is_reparse(meta: &std::fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        return meta.file_attributes() & 0x400 != 0;
    }
    #[cfg(not(windows))]
    {
        let _ = meta;
        false
    }
}
