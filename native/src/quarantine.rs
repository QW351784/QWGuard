//! 隔离库：查到的威胁不直接删，先关进隔离区
//!
//! 用户要求的效果：像 360 那样，文件被收走之后资源管理器里原目录就"没有"这个文件了；
//! 隔离区里能看、能恢复回原位置、能手动清、能按文件名搜、能反选、能一键清。
//!
//! 存储设计：
//! - 索引 `quarantine.json`：id / 原名 / 原路径 / 大小 / 时间 / 引擎 / 原因 / sha256
//! - 内容 `<id>.qqt`：QQT2 头 + AES-256-GCM 分块密文（每文件 HMAC 子密钥、随机 nonce）
//!   老版本 QQT1（单字节 XOR）仍能恢复，升级不会让旧隔离项作废
//! - 不整体读进内存，64KB 分块流式处理，几个 G 的文件也不炸内存

use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::ffi::c_char;
use std::fs;
use std::io::{ErrorKind, Read, Write};
use std::path::{Path, PathBuf};

use crate::ext::cfg_dir;
use crate::{cstr, fail, ok};

const MAGIC2: [u8; 4] = *b"QQT2";
const MAGIC1: [u8; 4] = *b"QQT1";
const BLOCK: usize = 65536;
const TAG: usize = 16;

#[derive(Serialize, Deserialize, Clone, Default)]
pub struct QItem {
    pub id: String,
    pub name: String,
    pub origin: String,
    pub size: u64,
    pub time: u64,
    pub engine: String,
    pub reason: String,
    pub sha: String,
    #[serde(default)]
    pub restored: bool,
}

fn qdir() -> PathBuf {
    let d = cfg_dir().join("quarantine");
    let _ = fs::create_dir_all(&d);
    d
}

fn index_path() -> PathBuf {
    cfg_dir().join("quarantine.json")
}

fn load_index() -> Vec<QItem> {
    fs::read_to_string(index_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_index(items: &[QItem]) {
    let text = serde_json::to_string_pretty(items).unwrap_or_else(|_| "[]".into());
    let _ = crate::write_atomic(&index_path(), &text);
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 40 && id.chars().all(|c| c.is_ascii_hexdigit())
}

fn qfile(id: &str) -> PathBuf {
    // id 只允许十六进制：挡住 ../../ 这类路径穿越
    debug_assert!(valid_id(id));
    qdir().join(format!("{id}.qqt"))
}

fn new_id() -> String {
    let d = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    format!("{:x}{:06x}", d.as_secs(), d.subsec_micros())
}

fn hex32(k: &[u8; 32]) -> String {
    k.iter().map(|b| format!("{b:02x}")).collect()
}

fn parse_hex32(s: &str) -> Option<[u8; 32]> {
    if s.len() != 64 || !s.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let mut k = [0u8; 32];
    for i in 0..32 {
        k[i] = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(k)
}

/// 隔离库主密钥：32 字节，随机生成，存 `quarantine.key`。
/// 它防的是「.qqt 被随手拷走 / 被其它程序误读」，不是防本机同用户逆向——
/// 同用户能读配置目录，任何纯本机方案都挡不住，这一点不吹。
fn master_key() -> std::io::Result<[u8; 32]> {
    let path = qdir().join("quarantine.key");
    if let Ok(t) = fs::read_to_string(&path) {
        return parse_hex32(t.trim())
            .ok_or_else(|| std::io::Error::new(ErrorKind::InvalidData, "隔离库密钥损坏"));
    }
    let mut k = [0u8; 32];
    getrandom::getrandom(&mut k)
        .map_err(|e| std::io::Error::other(format!("随机数生成失败: {e}")))?;
    match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
    {
        Ok(mut f) => {
            f.write_all(hex32(&k).as_bytes())?;
            f.flush()?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o600));
            }
            Ok(k)
        }
        Err(e) if e.kind() == ErrorKind::AlreadyExists => {
            let t = fs::read_to_string(&path)?;
            parse_hex32(t.trim())
                .ok_or_else(|| std::io::Error::new(ErrorKind::InvalidData, "隔离库密钥损坏"))
        }
        Err(e) => Err(e),
    }
}

/// 每个隔离文件独立子密钥：HMAC-SHA256(主密钥, id)
fn file_key(master: &[u8; 32], id: &str) -> [u8; 32] {
    use hmac::{Hmac, Mac};
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(master).expect("HMAC 接受任意长度密钥");
    mac.update(id.as_bytes());
    let out = mac.finalize().into_bytes();
    let mut k = [0u8; 32];
    k.copy_from_slice(&out);
    k
}

fn chunk_aad(id: &str, idx: u32, size: u64) -> Vec<u8> {
    let mut a = id.as_bytes().to_vec();
    a.extend_from_slice(&idx.to_be_bytes());
    a.extend_from_slice(&size.to_le_bytes());
    a
}

fn nonce_for(base: &[u8; 12], idx: u32) -> [u8; 12] {
    let mut n = *base;
    n[8..12].copy_from_slice(&idx.to_be_bytes());
    n
}

/// QQT2 格式：4 魔数 + 8 原始大小 + 12 随机 nonce 基 + 若干
/// 「4 字节密文长度 + AES-256-GCM 密文（含 16 字节 tag）」块。
/// 分块是为了几个 G 的文件也能流式处理，不整体进内存。
fn seal(src: &Path, dst: &Path, id: &str, size: u64) -> std::io::Result<()> {
    use aes_gcm::aead::{Aead, Payload};
    use aes_gcm::{Aes256Gcm, KeyInit};
    let master = master_key()?;
    let cipher = Aes256Gcm::new_from_slice(&file_key(&master, id))
        .map_err(|e| std::io::Error::other(format!("初始化加密失败: {e}")))?;
    let mut base = [0u8; 12];
    getrandom::getrandom(&mut base)
        .map_err(|e| std::io::Error::other(format!("随机数生成失败: {e}")))?;

    let mut f = fs::File::open(src)?;
    let mut out = fs::File::create(dst)?;
    out.write_all(&MAGIC2)?;
    out.write_all(&size.to_le_bytes())?;
    out.write_all(&base)?;

    let mut buf = vec![0u8; BLOCK];
    let mut idx = 0u32;
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        let nonce = nonce_for(&base, idx);
        let aad = chunk_aad(id, idx, size);
        let ct = cipher
            .encrypt(
                (&nonce).into(),
                Payload {
                    msg: &buf[..n],
                    aad: &aad,
                },
            )
            .map_err(|e| std::io::Error::other(format!("加密失败: {e}")))?;
        out.write_all(&(ct.len() as u32).to_le_bytes())?;
        out.write_all(&ct)?;
        idx = idx
            .checked_add(1)
            .ok_or_else(|| std::io::Error::new(ErrorKind::InvalidData, "文件过大，分块计数溢出"))?;
    }
    out.flush()?;
    Ok(())
}

fn unseal(src: &Path, dst: &Path, id: &str) -> std::io::Result<()> {
    let mut f = fs::File::open(src)?;
    let mut magic = [0u8; 4];
    f.read_exact(&mut magic)?;
    if magic == MAGIC1 {
        return unseal_legacy(f, dst);
    }
    if magic != MAGIC2 {
        return Err(std::io::Error::new(
            ErrorKind::InvalidData,
            "隔离文件头损坏",
        ));
    }

    use aes_gcm::aead::{Aead, Payload};
    use aes_gcm::{Aes256Gcm, KeyInit};
    let master = master_key()?;
    let cipher = Aes256Gcm::new_from_slice(&file_key(&master, id))
        .map_err(|e| std::io::Error::other(format!("初始化解密失败: {e}")))?;

    let mut head = [0u8; 20]; // size 8 + nonce 12
    f.read_exact(&mut head)?;
    let size = u64::from_le_bytes(head[0..8].try_into().unwrap());
    let mut base = [0u8; 12];
    base.copy_from_slice(&head[8..20]);

    let mut out = fs::File::create(dst)?;
    let mut written = 0u64;
    let mut idx = 0u32;
    while written < size {
        let mut lb = [0u8; 4];
        f.read_exact(&mut lb)?;
        let clen = u32::from_le_bytes(lb) as usize;
        if !(TAG..=BLOCK + TAG).contains(&clen) {
            return Err(std::io::Error::new(
                ErrorKind::InvalidData,
                "隔离文件分块损坏",
            ));
        }
        let mut ct = vec![0u8; clen];
        f.read_exact(&mut ct)?;
        let nonce = nonce_for(&base, idx);
        let aad = chunk_aad(id, idx, size);
        let pt = cipher
            .decrypt(
                (&nonce).into(),
                Payload {
                    msg: &ct,
                    aad: &aad,
                },
            )
            .map_err(|_| std::io::Error::new(ErrorKind::InvalidData, "隔离文件损坏或密钥不匹配"))?;
        let remain = size - written;
        let take = (pt.len() as u64).min(remain) as usize;
        out.write_all(&pt[..take])?;
        written += take as u64;
        idx = idx
            .checked_add(1)
            .ok_or_else(|| std::io::Error::new(ErrorKind::InvalidData, "文件过大，分块计数溢出"))?;
        if pt.len() as u64 > remain {
            return Err(std::io::Error::new(
                ErrorKind::InvalidData,
                "隔离文件大小与索引不一致",
            ));
        }
    }
    out.flush()?;
    Ok(())
}

/// 兼容老版本 QQT1（单字节 XOR）。升级后老隔离项还能恢复，不会一升级就全废。
fn unseal_legacy(mut f: fs::File, dst: &Path) -> std::io::Result<()> {
    let mut head = [0u8; 9]; // 原头共 13 字节，已读走 4
    f.read_exact(&mut head)?;
    let size = u64::from_le_bytes(head[0..8].try_into().unwrap());
    let key = head[8];
    let mut out = fs::File::create(dst)?;
    let mut buf = vec![0u8; BLOCK];
    let mut written = 0u64;
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        for b in buf.iter_mut().take(n) {
            *b ^= key;
        }
        let remain = (size - written) as usize;
        let take = remain.min(n);
        out.write_all(&buf[..take])?;
        written += take as u64;
        if written >= size {
            break;
        }
    }
    out.flush()?;
    Ok(())
}

fn sha256_of(path: &Path) -> String {
    let mut f = match fs::File::open(path) {
        Ok(f) => f,
        Err(_) => return String::new(),
    };
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; BLOCK];
    loop {
        match f.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => hasher.update(&buf[..n]),
            Err(_) => break,
        }
    }
    hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

// ================= 导出接口 =================

/// 内部版本：不走 FFI，后台线程直接调用
pub(crate) fn add_internal(p: &str, engine: &str, reason: &str) -> Result<String, String> {
    let src = Path::new(p);
    let meta = fs::symlink_metadata(src).map_err(|_| "文件不存在".to_string())?;
    if !meta.is_file() {
        return Err("只能隔离单个文件，目录不能直接隔离".into());
    }
    if meta.file_type().is_symlink() {
        return Err("符号链接不隔离".into());
    }

    let size = meta.len();
    let id = new_id();
    let sha = sha256_of(src);
    let dst = qfile(&id);

    seal(src, &dst, &id, size).map_err(|e| format!("写入隔离区失败: {e}"))?;
    if let Err(e) = fs::remove_file(src) {
        let _ = fs::remove_file(&dst);
        return Err(format!("隔离后删原文件失败（可能被占用）: {e}"));
    }

    let item = QItem {
        id: id.clone(),
        name: src
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default(),
        origin: p.to_string(),
        size,
        time: crate::util::now_secs(),
        engine: if engine.is_empty() {
            "manual".into()
        } else {
            engine.to_string()
        },
        reason: reason.to_string(),
        sha,
        restored: false,
    };
    let mut idx = load_index();
    idx.insert(0, item);
    save_index(&idx);
    Ok(id)
}

/// 把文件收进隔离库（成功返回 0，原文件已被移除）
#[no_mangle]
pub extern "C" fn quarantine_add(
    path: *const c_char,
    engine: *const c_char,
    reason: *const c_char,
    buf: *mut u8,
    len: usize,
) -> i32 {
    crate::ffi_guard!(buf, len, {
        if let Err(e) = crate::security::require_admin("将文件移入隔离库") {
            return fail(buf, len, -5, &e);
        }
        let Some(p) = cstr(path) else {
            return fail(buf, len, -1, "路径为空");
        };
        let engine_s = cstr(engine).unwrap_or_default();
        let reason_s = cstr(reason).unwrap_or_default();
        let src = Path::new(&p);

        let Ok(meta) = fs::symlink_metadata(src) else {
            return fail(buf, len, -3, "文件不存在");
        };
        if !meta.is_file() {
            return fail(buf, len, -3, "只能隔离单个文件，目录不能直接隔离");
        }
        if meta.file_type().is_symlink() {
            return fail(buf, len, -3, "符号链接不隔离");
        }

        let size = meta.len();
        let id = new_id();
        let sha = sha256_of(src);
        let dst = qfile(&id);

        if let Err(e) = seal(src, &dst, &id, size) {
            let _ = fs::remove_file(&dst);
            return fail(buf, len, -3, &format!("写入隔离区失败: {e}"));
        }

        // 原文件删掉 —— 这一步之后，资源管理器里那个目录就看不到它了
        if let Err(e) = fs::remove_file(src) {
            let _ = fs::remove_file(&dst);
            return fail(
                buf,
                len,
                -3,
                &format!("隔离后删原文件失败（可能被占用）: {e}"),
            );
        }

        let item = QItem {
            id: id.clone(),
            name: src
                .file_name()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_default(),
            origin: p.clone(),
            size,
            time: crate::util::now_secs(),
            engine: if engine_s.is_empty() {
                "manual".into()
            } else {
                engine_s
            },
            reason: reason_s,
            sha: sha.clone(),
            restored: false,
        };

        let mut idx = load_index();
        idx.insert(0, item.clone());
        save_index(&idx);

        ok(
            buf,
            len,
            "已移入隔离库",
            json!({
                "id": id,
                "name": item.name,
                "origin": p,
                "size": size,
                "sha": sha,
                "count": idx.len()
            }),
        )
    })
}

/// 列出全部隔离项
#[no_mangle]
pub extern "C" fn quarantine_list(buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        let idx = load_index();
        let total: u64 = idx.iter().map(|i| i.size).sum();
        ok(
            buf,
            len,
            "隔离库",
            json!({
                "items": idx,
                "count": idx.len(),
                "total_bytes": total
            }),
        )
    })
}

/// 恢复到原位置（原路径被占用自动加 _restored 后缀，不覆盖）
#[no_mangle]
pub extern "C" fn quarantine_restore(id: *const c_char, buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        if let Err(e) = crate::security::require_admin("恢复隔离文件") {
            return fail(buf, len, -5, &e);
        }
        let Some(id) = cstr(id) else {
            return fail(buf, len, -1, "参数为空");
        };
        if !valid_id(&id) {
            return fail(buf, len, -1, "隔离项编号不合法");
        }
        let mut idx = load_index();
        let Some(pos) = idx.iter().position(|i| i.id == id) else {
            return fail(buf, len, -3, "隔离库里没有这一项");
        };
        let item = idx[pos].clone();
        let src = qfile(&id);
        if !src.exists() {
            return fail(buf, len, -3, "隔离文件已丢失，无法恢复");
        }

        let origin = PathBuf::from(&item.origin);
        if let Some(parent) = origin.parent() {
            let _ = fs::create_dir_all(parent);
        }

        let mut dst = origin.clone();
        if dst.exists() {
            let stem = origin
                .file_stem()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_else(|| "restored".into());
            let ext = origin
                .extension()
                .map(|s| format!(".{}", s.to_string_lossy()))
                .unwrap_or_default();
            for n in 1..1000 {
                let cand = origin.with_file_name(format!("{stem}_restored{n}{ext}"));
                if !cand.exists() {
                    dst = cand;
                    break;
                }
            }
        }

        if let Err(e) = unseal(&src, &dst, &id) {
            return fail(buf, len, -3, &format!("恢复失败: {e}"));
        }
        let _ = fs::remove_file(&src);
        idx.remove(pos);
        save_index(&idx);

        ok(
            buf,
            len,
            "已恢复到原位置",
            json!({
                "id": id,
                "restored_to": dst.to_string_lossy(),
                "count": idx.len()
            }),
        )
    })
}

/// 手动清除单项（彻底删掉，不可恢复）
#[no_mangle]
pub extern "C" fn quarantine_delete(id: *const c_char, buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        if let Err(e) = crate::security::require_admin("彻底删除隔离文件") {
            return fail(buf, len, -5, &e);
        }
        let Some(id) = cstr(id) else {
            return fail(buf, len, -1, "参数为空");
        };
        if !valid_id(&id) {
            return fail(buf, len, -1, "隔离项编号不合法");
        }
        let mut idx = load_index();
        let exists = idx.iter().any(|i| i.id == id);
        let _ = fs::remove_file(qfile(&id));
        idx.retain(|i| i.id != id);
        save_index(&idx);
        if !exists {
            return fail(buf, len, -3, "隔离库里没有这一项");
        }
        ok(
            buf,
            len,
            "已彻底删除",
            json!({"id": id, "count": idx.len()}),
        )
    })
}

/// 一键清空
#[no_mangle]
pub extern "C" fn quarantine_clear(buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        if let Err(e) = crate::security::require_admin("清空隔离库") {
            return fail(buf, len, -5, &e);
        }
        let idx = load_index();
        let mut removed = 0u32;
        for i in &idx {
            if fs::remove_file(qfile(&i.id)).is_ok() {
                removed += 1;
            }
        }
        // 清掉目录里可能残留的 qqt
        if let Ok(rd) = fs::read_dir(qdir()) {
            for e in rd.flatten() {
                if e.path().extension().map(|x| x == "qqt").unwrap_or(false)
                    && fs::remove_file(e.path()).is_ok()
                {
                    removed += 1;
                }
            }
        }
        save_index(&[]);
        ok(
            buf,
            len,
            "隔离库已清空",
            json!({"removed": removed, "count": 0}),
        )
    })
}
