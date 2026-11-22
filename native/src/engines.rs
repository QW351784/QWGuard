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
        // 不设大小上限：多大的文件都流式读一遍算 SHA-256（1MB 缓冲，内存恒定）
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

/// 在字节流里找一个固定串（PE 的导入名、命令串都靠它）
fn pat_in(data: &[u8], pat: &[u8]) -> bool {
    if pat.is_empty() || data.len() < pat.len() {
        return false;
    }
    data.windows(pat.len()).any(|w| w == pat)
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

    // ⑤ 覆盖层（overlay）：最后一个节的原始数据后面还挂着一大段 —— 释放器/捆绑器典型结构
    let mut last_end = 0usize;
    for i in 0..num_sections.min(96) {
        let s = sect_table + i * 40;
        let rawsize = u32::from_le_bytes([data[s + 16], data[s + 17], data[s + 18], data[s + 19]]) as usize;
        let rawptr = u32::from_le_bytes([data[s + 20], data[s + 21], data[s + 22], data[s + 23]]) as usize;
        last_end = last_end.max(rawptr.saturating_add(rawsize));
    }
    if last_end > 0 && last_end < data.len() {
        let overlay = data.len() - last_end;
        if overlay > 8192 && overlay.saturating_mul(10) > data.len() {
            out.push(format!("HEUR.Overlay.{:.0}KB", overlay as f64 / 1024.0));
            // 覆盖层里嵌着第二个 PE（MZ + 合法 e_lfanew），一装一放的典型
            let tail = &data[last_end..];
            let mut i = 0usize;
            while i + 0x40 < tail.len() {
                if &tail[i..i + 2] == b"MZ" {
                    let lf = u32::from_le_bytes([tail[i + 0x3c], tail[i + 0x3d], tail[i + 0x3e], tail[i + 0x3f]]) as usize;
                    if lf < 0x400 && i + lf + 4 <= tail.len() && &tail[i + lf..i + lf + 4] == b"PE\0\0" {
                        out.push("HEUR.Dropper.EmbeddedPE".to_string());
                        break;
                    }
                }
                i += 1;
            }
        }
    }

    // ⑥ 可写且可执行的节：正常编译器不会产出这种节
    for i in 0..num_sections.min(96) {
        let s = sect_table + i * 40;
        let chars = u32::from_le_bytes([data[s + 36], data[s + 37], data[s + 38], data[s + 39]]);
        if chars & 0x2000_0000 != 0 && chars & 0x8000_0000 != 0 {
            out.push("HEUR.WX.Section".to_string());
            break;
        }
    }

    // ⑦ 入口点 RVA 为 0：被打包器改过头的常见特征
    let ep_off = coff + 20 + 16;
    if ep_off + 4 <= data.len() {
        let ep = u32::from_le_bytes([data[ep_off], data[ep_off + 1], data[ep_off + 2], data[ep_off + 3]]);
        if ep == 0 {
            out.push("HEUR.EP.Zero".to_string());
        }
    }

    // ⑧ 无文件落地 / LOLBIN 命令串
    const LOLBINS: [(&str, &[u8]); 6] = [
        ("EncodedCommand", b"-EncodedCommand"),
        ("PSEnc", b"-enc "),
        ("CertUtil", b"certutil -urlcache"),
        ("BITSAdmin", b"bitsadmin /transfer"),
        ("MSHTA", b"mshta http"),
        ("ScrobjDll", b"scrobj.dll"),
    ];
    for (name, pat) in LOLBINS {
        if pat_in(data, pat) {
            out.push(format!("HEUR.Cmd.{name}"));
        }
    }

    // ⑨ 键盘记录组合、卷影删除（勒索）
    if pat_in(data, b"SetWindowsHookEx") && pat_in(data, b"GetAsyncKeyState") {
        out.push("HEUR.Keylogger".to_string());
    }
    if pat_in(data, b"vssadmin delete") || pat_in(data, b"wbadmin delete") {
        out.push("HEUR.Ransom.ShadowDel".to_string());
    }

    // ⑩ 整文件高熵（前面只按可执行节判过，这里兜住「整包都被加密」的情况）
    if data.len() > 65536 {
        let e = entropy(data);
        if e > 7.40 {
            out.push(format!("HEUR.FileEntropy.{:.2}", e));
        }
    }

    // 去重：同一个规则只报一次
    out.sort();
    out.dedup();
}

// ================= 规则库：内置默认 YARA + 本地哈希导入（全部离线） =================

/// 内置的原创基础规则（自己写的，不是抄社区规则集，许可证干净）
const DEFAULT_YARA: &str = r#"// QW 引擎内置基础规则 · 原创 · 随 QW 安全电脑管家分发
// 这些规则只匹配公开的行为特征，不针对任何具体家族

rule QW_PS_Encoded_Download
{
    meta:
        author = "QWGuard"
        desc = "PowerShell 编码参数配合下载执行"
        severity = 6
    strings:
        $enc  = "-EncodedCommand" ascii nocase
        $enc2 = "-enc " ascii nocase
        $dl   = "DownloadString" ascii nocase
        $dl2  = "DownloadFile" ascii nocase
        $b64  = "FromBase64String" ascii nocase
        $iex  = "Invoke-Expression" ascii nocase
    condition:
        filesize < 8MB and ((($enc or $enc2) and ($dl or $dl2)) or ($b64 and $iex))
}

rule QW_PS_Hidden_Window
{
    meta:
        author = "QWGuard"
        desc = "隐藏窗口执行 PowerShell"
        severity = 5
    strings:
        $a = "-WindowStyle Hidden" ascii nocase
        $b = "-w hidden" ascii nocase
        $c = "-nop" ascii nocase
        $d = "-NoProfile" ascii nocase
        $e = "powershell" ascii nocase
    condition:
        filesize < 8MB and $e and (($a or $b) and ($c or $d))
}

rule QW_CertUtil_Download
{
    meta:
        author = "QWGuard"
        desc = "用 certutil 下载并解码载荷"
        severity = 6
    strings:
        $a = "certutil" ascii nocase
        $b = "-urlcache" ascii nocase
        $c = "-decode" ascii nocase
    condition:
        filesize < 8MB and $a and ($b or $c)
}

rule QW_Miner_Stratum
{
    meta:
        author = "QWGuard"
        desc = "矿池协议字符串"
        severity = 6
    strings:
        $a = "stratum+tcp://" ascii nocase
        $b = "stratum+ssl://" ascii nocase
        $c = "--donate-level" ascii nocase
    condition:
        filesize < 20MB and ($a or $b) and $c
}

rule QW_Miner_Xmrig
{
    meta:
        author = "QWGuard"
        desc = "XMRig 钱包与矿池参数"
        severity = 5
    strings:
        $a = "xmrig" ascii nocase
        $b = "--coin" ascii nocase
        $c = "--rig-id" ascii nocase
    condition:
        filesize < 20MB and $a and ($b or $c)
}

rule QW_Ransom_Note
{
    meta:
        author = "QWGuard"
        desc = "勒索说明文案"
        severity = 7
    strings:
        $a = "Your files have been encrypted" ascii nocase
        $b = "all your files are encrypted" ascii nocase
        $c = "recover your files" ascii nocase
        $d = "bitcoin" ascii nocase
    condition:
        filesize < 2MB and ($a or $b) and ($c or $d)
}

rule QW_Ransom_ShadowCopy
{
    meta:
        author = "QWGuard"
        desc = "删除卷影副本（勒索前置动作）"
        severity = 7
    strings:
        $a = "vssadmin" ascii nocase
        $b = "delete shadows" ascii nocase
        $c = "wbadmin" ascii nocase
        $d = "delete catalog" ascii nocase
    condition:
        filesize < 8MB and (($a and $b) or ($c and $d))
}

rule QW_Inject_Triplet
{
    meta:
        author = "QWGuard"
        desc = "远程注入三件套"
        severity = 6
    strings:
        $a = "VirtualAllocEx" ascii
        $b = "WriteProcessMemory" ascii
        $c = "CreateRemoteThread" ascii
    condition:
        filesize < 20MB and all of them
}

rule QW_Keylogger_API
{
    meta:
        author = "QWGuard"
        desc = "键盘记录 API 组合"
        severity = 6
    strings:
        $a = "GetAsyncKeyState" ascii
        $b = "SetWindowsHookEx" ascii
        $c = "GetKeyboardState" ascii
    condition:
        filesize < 20MB and $a and ($b or $c)
}

rule QW_AntiSandbox_Strings
{
    meta:
        author = "QWGuard"
        desc = "反沙箱环境探测字符串"
        severity = 5
    strings:
        $a = "SbieDll.dll" ascii nocase
        $b = "VBoxService" ascii nocase
        $c = "vmtoolsd" ascii nocase
        $d = "sandboxie" ascii nocase
        $e = "wine_get_unix_file_name" ascii nocase
    condition:
        filesize < 20MB and 2 of them
}

rule QW_AMSI_Bypass
{
    meta:
        author = "QWGuard"
        desc = "绕过 AMSI 扫描"
        severity = 7
    strings:
        $a = "amsi.dll" ascii nocase
        $b = "AmsiScanBuffer" ascii nocase
    condition:
        filesize < 8MB and all of them
}

rule QW_ETW_Patch
{
    meta:
        author = "QWGuard"
        desc = "篡改 ETW 事件写入"
        severity = 6
    strings:
        $a = "EtwEventWrite" ascii
        $b = "ntdll" ascii nocase
    condition:
        filesize < 20MB and all of them
}

rule QW_Webshell_Eval_Post
{
    meta:
        author = "QWGuard"
        desc = "PHP/ASP 一句话木马特征"
        severity = 8
    strings:
        $a = "eval($_POST" ascii nocase
        $b = "eval($_REQUEST" ascii nocase
        $c = "assert($_POST" ascii nocase
        $d = "eval($_GET" ascii nocase
    condition:
        filesize < 1MB and any of them
}

rule QW_SelfDelete_Cmd
{
    meta:
        author = "QWGuard"
        desc = "自删除脚本"
        severity = 4
    strings:
        $a = "cmd /c del" ascii nocase
        $b = "ping -n" ascii nocase
        $c = "/f /q" ascii nocase
    condition:
        filesize < 4MB and $a and ($b or $c)
}

rule QW_Defender_Disable
{
    meta:
        author = "QWGuard"
        desc = "关闭系统防护"
        severity = 7
    strings:
        $a = "DisableAntiSpyware" ascii nocase
        $b = "DisableRealtimeMonitoring" ascii nocase
        $c = "Add-MpPreference" ascii nocase
        $d = "Set-MpPreference" ascii nocase
    condition:
        filesize < 8MB and ($a or $b) and ($c or $d)
}

rule QW_Taskkill_AV
{
    meta:
        author = "QWGuard"
        desc = "强杀安全软件进程"
        severity = 7
    strings:
        $a = "taskkill" ascii nocase
        $b = "/f /im" ascii nocase
        $c = "MsMpEng" ascii nocase
        $d = "360tray" ascii nocase
        $e = "hipstray" ascii nocase
        $f = "wsctrl" ascii nocase
    condition:
        filesize < 8MB and $a and $b and 2 of ($c, $d, $e, $f)
}

rule QW_Persistence_RunKey
{
    meta:
        author = "QWGuard"
        desc = "写注册表启动项做持久化"
        severity = 5
    strings:
        $a = "CurrentVersion\\Run" ascii nocase
        $b = "schtasks /create" ascii nocase
        $c = "reg add" ascii nocase
    condition:
        filesize < 8MB and ($a or $b) and $c
}

rule QW_UPX_Section
{
    meta:
        author = "QWGuard"
        desc = "UPX 壳节名"
        severity = 3
    strings:
        $a = "UPX0" ascii
        $b = "UPX1" ascii
        $c = "UPX!" ascii
    condition:
        filesize < 40MB and 2 of them
}
"#;

fn ensure_default_rules_inner() {
    let dir = rules_dir();
    let _ = fs::create_dir_all(&dir);
    let yara = dir.join("qw_basic.yar");
    if !yara.exists() {
        let _ = fs::write(&yara, DEFAULT_YARA);
    }
    let hash = dir.join("hash_blacklist.txt");
    if !hash.exists() {
        let _ = fs::write(
            &hash,
            "# QW 特征库 · SHA-256 黑名单\n# 一行一个 64 位十六进制哈希，# 开头是注释\n",
        );
    }
    let name = dir.join("name_blacklist.txt");
    if !name.exists() {
        let _ = fs::write(&name, "# QW 特征库 · 文件名子串黑名单\n# 一行一个子串，不区分大小写\n");
    }
}

pub(crate) fn ensure_default_rules() {
    ensure_default_rules_inner();
}

pub(crate) fn default_yara_rules() -> PathBuf {
    ensure_default_rules_inner();
    rules_dir().join("qw_basic.yar")
}

fn merge_hashes(incoming: Vec<String>) -> Result<(usize, usize, usize), String> {
    ensure_default_rules_inner();
    let parsed = incoming.len();
    if parsed == 0 {
        return Err("没解析到 SHA-256（需要 64 位十六进制）".into());
    }
    let path = rules_dir().join("hash_blacklist.txt");
    let mut set: std::collections::HashSet<String> = std::collections::HashSet::new();
    if let Ok(old) = fs::read_to_string(&path) {
        for line in old.lines() {
            let h = line.trim().to_lowercase();
            if h.len() == 64 && h.bytes().all(|b| b.is_ascii_hexdigit()) {
                set.insert(h);
            }
        }
    }
    let before = set.len();
    for h in incoming {
        set.insert(h);
    }
    let total = set.len();
    let added = total - before;

    let mut all: Vec<&String> = set.iter().collect();
    all.sort();
    const CAP: usize = 300_000;
    let kept = all.len().min(CAP);
    let mut body = String::with_capacity(kept * 65);
    for h in all.iter().take(kept) {
        body.push_str(h);
        body.push('\n');
    }
    fs::write(
        &path,
        format!("# QW 特征库 · SHA-256 黑名单 · 共 {kept} 条\n{body}"),
    )
    .map_err(|e| format!("写规则库失败: {e}"))?;
    Ok((parsed, added, kept))
}

/// 从本地 txt 导入哈希（一行一个，任意分隔符都行）
pub(crate) fn import_hashes(src: &str) -> Result<(usize, usize, usize), String> {
    let text = fs::read_to_string(src).map_err(|e| format!("读不了这个文件: {e}"))?;
    let mut incoming = Vec::new();
    for tok in text.split(|c: char| {
        c.is_whitespace() || c == ',' || c == ';' || c == '|' || c == '\'' || c == '"'
    }) {
        let t = tok.trim().to_lowercase();
        if t.len() == 64 && t.bytes().all(|b| b.is_ascii_hexdigit()) {
            incoming.push(t);
        }
    }
    merge_hashes(incoming)
}

// 这里原来有 abuse.ch MalwareBazaar 的拉取实现（http_post + bazaar_pull）。
// 它需要用户自己去 abuse.ch 注册并申请 Auth-Key —— 界面上从来没有接过按钮，
// 属于「留着但没人用、还要求账号」的死代码，整段删除。
// 现在规则库只有本地来源：内置 qw_basic.yar + 用户自己导入的 txt 黑名单。

/// 规则库状态：各文件有效行数
pub(crate) fn rules_status() -> serde_json::Value {
    ensure_default_rules_inner();
    let dir = rules_dir();
    let count = |p: PathBuf| {
        fs::read_to_string(p)
            .map(|t| {
                t.lines()
                    .filter(|l| {
                        let s = l.trim();
                        !s.is_empty() && !s.starts_with('#')
                    })
                    .count()
            })
            .unwrap_or(0)
    };
    serde_json::json!({
        "dir": dir.to_string_lossy(),
        "hashes": count(dir.join("hash_blacklist.txt")),
        "names": count(dir.join("name_blacklist.txt")),
        "yara": dir.join("qw_basic.yar").exists(),
        "yara_path": dir.join("qw_basic.yar").to_string_lossy(),
    })
}
