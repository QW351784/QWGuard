//! QW 引擎的两个内置子引擎：启发式（heuristic）与特征库（signature）
//!
//! 都是进程内纯 Rust 实现，不起外部进程：
//! - `signature`：SHA-256 黑名单 + 文件名黑名单，O(1) 查表
//! - `heuristic`：PE 结构 / 节区熵 / 注入型导入 / 加壳签名 / 脚本混淆 / 双扩展名
//!
//! 规则文件放 `%APPDATA%\QWGuard\rules\`，没有规则文件时引擎照常工作、只是不命中。

use sha2::{Digest, Sha256};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use crate::ext::cfg_dir;

const MAX_PE_BYTES: usize = 8 * 1024 * 1024;
const MAX_SCRIPT_BYTES: usize = 512 * 1024;

fn rules_dir() -> PathBuf {
    cfg_dir().join("rules")
}

fn read_head(p: &Path, limit: usize) -> std::io::Result<Vec<u8>> {
    let mut f = fs::File::open(p)?;
    let cap = limit.min(16 * 1024 * 1024);
    let mut buf = vec![0u8; cap];
    let mut n = 0usize;
    loop {
        let r = f.read(&mut buf[n..])?;
        if r == 0 {
            break;
        }
        n += r;
        if n == buf.len() {
            break;
        }
    }
    buf.truncate(n);
    Ok(buf)
}

fn read_head_text(p: &Path, limit: usize) -> std::io::Result<String> {
    let b = read_head(p, limit)?;
    Ok(String::from_utf8_lossy(&b).to_string())
}

fn sha256_file(p: &Path) -> std::io::Result<String> {
    let mut f = fs::File::open(p)?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(format!("{:x}", h.finalize()))
}

/// 特征库引擎：SHA-256 黑名单 + 文件名黑名单
pub(crate) fn signature_scan(path: &str) -> (bool, Vec<String>) {
    let p = Path::new(path);
    let mut threats = Vec::new();

    // 文件名黑名单：rules/name_blacklist.txt，每行一条子串，# 开头是注释
    if let Ok(text) = fs::read_to_string(rules_dir().join("name_blacklist.txt")) {
        let fname = p
            .file_name()
            .map(|s| s.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        for line in text.lines() {
            let pat = line.trim();
            if pat.is_empty() || pat.starts_with('#') {
                continue;
            }
            if fname.contains(&pat.to_lowercase()) {
                threats.push(format!("SIG.Name.{pat}"));
            }
        }
    }

    // SHA-256 黑名单：rules/hash_blacklist.txt，每行一个 64 位 hex
    if p.is_file() {
        if let Ok(meta) = p.metadata() {
            if meta.len() <= 512 * 1024 * 1024 {
                if let Ok(digest) = sha256_file(p) {
                    if let Ok(text) = fs::read_to_string(rules_dir().join("hash_blacklist.txt")) {
                        for line in text.lines() {
                            let h = line.trim().to_lowercase();
                            if h.len() == 64 && h == digest {
                                let short: String = digest.chars().take(16).collect();
                                threats.push(format!("SIG.Sha256.{short}"));
                                break;
                            }
                        }
                    }
                }
            }
        }
    }

    (!threats.is_empty(), threats)
}

/// 启发式引擎：看文件结构而不是特征码，专门抓免杀和未知样本
pub(crate) fn heuristic_scan(path: &str) -> (bool, Vec<String>) {
    let p = Path::new(path);
    let mut threats = Vec::new();
    if !p.is_file() {
        return (false, threats);
    }

    let ext = p
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();

    // 双扩展名伪装：报告.pdf.exe / 图片.jpg.scr
    if matches!(ext.as_str(), "exe" | "scr" | "com" | "pif" | "bat" | "cmd") {
        if let Some(stem) = p.file_stem() {
            if let Some(se) = Path::new(stem).extension() {
                let se = se.to_string_lossy().to_lowercase();
                if matches!(
                    se.as_str(),
                    "pdf" | "doc" | "docx" | "xls" | "xlsx" | "ppt" | "pptx" | "jpg" | "jpeg"
                        | "png" | "gif" | "txt" | "mp4" | "zip" | "rar" | "7z"
                ) {
                    threats.push(format!("HEUR.DoubleExt.{se}.{ext}"));
                }
            }
        }
    }

    // 脚本类：看内容
    if matches!(ext.as_str(), "ps1" | "psm1" | "vbs" | "vbe" | "bat" | "cmd" | "js" | "jse" | "hta" | "wsf") {
        if let Ok(text) = read_head_text(p, MAX_SCRIPT_BYTES) {
            script_checks(&text, &mut threats);
        }
    }

    // PE 类：结构 + 熵 + 导入 + 壳
    if matches!(ext.as_str(), "exe" | "dll" | "sys" | "ocx" | "scr" | "cpl") {
        if let Ok(data) = read_head(p, MAX_PE_BYTES) {
            pe_checks(&data, &mut threats);
        }
    }

    (!threats.is_empty(), threats)
}

fn script_checks(text: &str, out: &mut Vec<String>) {
    let low = text.to_lowercase();
    let mut found: Vec<String> = Vec::new();

    let pats: [(&str, &str); 10] = [
        ("-enc", "HEUR.Script.EncodedArg"),
        ("frombase64string", "HEUR.Script.Base64Decode"),
        ("downloadstring", "HEUR.Script.DownloadExec"),
        ("downloadfile", "HEUR.Script.DownloadExec"),
        ("wscript.shell", "HEUR.Script.WShell"),
        ("invoke-expression", "HEUR.Script.InvokeExpr"),
        ("iex(", "HEUR.Script.InvokeExpr"),
        ("certutil", "HEUR.Script.CertUtil"),
        ("bypass", "HEUR.Script.PolicyBypass"),
        ("hidden", "HEUR.Script.Hidden"),
    ];
    for (pat, rule) in pats {
        if low.contains(pat) {
            found.push(rule.to_string());
        }
    }
    if has_long_base64(&low, 300) {
        found.push("HEUR.Script.LongBase64".to_string());
    }

    // 单个关键词在正常脚本里太常见，至少要两条同时出现才算
    if found.len() >= 2 {
        out.extend(found);
    }
}

fn has_long_base64(s: &str, min: usize) -> bool {
    let mut run = 0usize;
    for ch in s.chars() {
        if ch.is_ascii_alphanumeric() || ch == '+' || ch == '/' || ch == '=' {
            run += 1;
            if run >= min {
                return true;
            }
        } else {
            run = 0;
        }
    }
    false
}

fn entropy(b: &[u8]) -> f64 {
    if b.is_empty() {
        return 0.0;
    }
    let mut cnt = [0u64; 256];
    for &x in b {
        cnt[x as usize] += 1;
    }
    let n = b.len() as f64;
    let mut e = 0.0;
    for c in cnt.iter() {
        if *c > 0 {
            let p = *c as f64 / n;
            e -= p * p.log2();
        }
    }
    e
}

fn shell_by_name(name: &str) -> Option<&'static str> {
    let n = name.to_uppercase();
    let shells = [
        ".UPX0", ".UPX1", ".UPX2", ".VMP0", ".VMP1", ".THEMIDA", ".THEMID",
        ".ASPACK", ".ASDATA", ".PETITE", ".MPRESS1", ".MPRESS2", ".PACKED",
        ".ENIGMA1", ".ENIGMA2", ".RLPACK", ".SPACK", ".BS.PACK", ".PEC1",
    ];
    for k in shells {
        if n.starts_with(k) {
            return Some(k);
        }
    }
    None
}

fn pe_checks(data: &[u8], out: &mut Vec<String>) {
    if data.len() < 0x40 || &data[0..2] != b"MZ" {
        return;
    }
    let e_lfanew = u32::from_le_bytes([data[0x3c], data[0x3d], data[0x3e], data[0x3f]]) as usize;
    if e_lfanew + 0x18 >= data.len() || &data[e_lfanew..e_lfanew + 4] != b"PE\0\0" {
        return;
    }
    let coff = e_lfanew + 4;
    let num_sections = u16::from_le_bytes([data[coff + 2], data[coff + 3]]) as usize;
    let opt_size = u16::from_le_bytes([data[coff + 16], data[coff + 17]]) as usize;
    let sect_table = coff + 20 + opt_size;
    if num_sections == 0 || sect_table + num_sections * 40 > data.len() {
        return;
    }

    // ① 壳签名 + ② 可执行节的高熵（加壳典型特征）
    for i in 0..num_sections.min(96) {
        let s = sect_table + i * 40;
        let raw_name = &data[s..s + 8];
        let name: String = raw_name
            .iter()
            .take_while(|b| **b != 0)
            .map(|b| *b as char)
            .collect();
        let rawsize = u32::from_le_bytes([data[s + 16], data[s + 17], data[s + 18], data[s + 19]]) as usize;
        let rawptr = u32::from_le_bytes([data[s + 20], data[s + 21], data[s + 22], data[s + 23]]) as usize;
        let chars = u32::from_le_bytes([data[s + 36], data[s + 37], data[s + 38], data[s + 39]]);

        if let Some(k) = shell_by_name(&name) {
            out.push(format!("HEUR.Packed.{k}"));
        }

        let exec = chars & 0x2000_0000 != 0;
        if exec && rawsize > 4096 && rawptr > 0 && rawptr < data.len() {
            let end = rawptr.saturating_add(rawsize.min(4 * 1024 * 1024)).min(data.len());
            if end > rawptr + 512 {
                let e = entropy(&data[rawptr..end]);
                if e > 7.25 {
                    out.push(format!("HEUR.PackedEntropy.{:.2}", e));
                }
            }
        }
    }

    // ③ 注入型导入组合：写内存 + 远程线程，单个出现不算
    let has_wpm = data.windows(19).any(|w| w == b"WriteProcessMemory");
    let has_crt = data.windows(19).any(|w| w == b"CreateRemoteThread");
    let has_vaex = data.windows(16).any(|w| w == b"VirtualAllocEx\0\0");
    if has_wpm && has_crt {
        out.push("HEUR.Inject.WPM+CRT".to_string());
    }
    if has_vaex && has_wpm {
        out.push("HEUR.Inject.VAEX+WPM".to_string());
    }

    // ④ 反调试 + 下载执行同时出现
    let has_dbg = data.windows(19).any(|w| w == b"IsDebuggerPresent\0");
    let has_url = data.windows(19).any(|w| w == b"URLDownloadToFile\0");
    if has_dbg && has_url {
        out.push("HEUR.Dropper.Dbg+URL".to_string());
    }

    // 去重：同一个规则只报一次
    out.sort();
    out.dedup();
}
