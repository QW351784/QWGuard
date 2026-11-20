//! 隔离库：查到的威胁不直接删，先关进隔离区
//!
//! 用户要求的效果：像 360 那样，文件被收走之后资源管理器里原目录就"没有"这个文件了；
//! 隔离区里能看、能恢复回原位置、能手动清、能按文件名搜、能反选、能一键清。
//!
//! 存储设计：
//! - 索引 `quarantine.json`：id / 原名 / 原路径 / 大小 / 时间 / 引擎 / 原因 / sha256
//! - 内容 `<id>.qqt`：13 字节头（魔数 QQT1 + 原始大小 + 每文件独立密钥）+ XOR 流式加密
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

const MAGIC: [u8; 4] = *b"QQT1";
const BLOCK: usize = 65536;

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
    let _ = fs::create_dir_all(cfg_dir());
    let _ = fs::write(
        index_path(),
        serde_json::to_string_pretty(items).unwrap_or_else(|_| "[]".into()),
    );
}

fn qfile(id: &str) -> PathBuf {
    qdir().join(format!("{id}.qqt"))
}

/// 每个隔离文件一个 XOR 密钥，按 id 派生，避免一把钥匙解全盘
fn key_for(id: &str) -> u8 {
    let mut h: u32 = 0x811c9dc5;
    for b in id.as_bytes() {
        h ^= *b as u32;
        h = h.wrapping_mul(0x01000193);
    }
    ((h % 251) as u8) + 1
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn new_id() -> String {
    let d = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    format!("{:x}{:06x}", d.as_secs(), d.subsec_micros())
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

fn seal(src: &Path, dst: &Path, key: u8, size: u64) -> std::io::Result<()> {
    let mut f = fs::File::open(src)?;
    let mut out = fs::File::create(dst)?;
    out.write_all(&MAGIC)?;
    out.write_all(&size.to_le_bytes())?;
    out.write_all(&[key])?;
    let mut buf = vec![0u8; BLOCK];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        for b in buf.iter_mut().take(n) {
            *b ^= key;
        }
        out.write_all(&buf[..n])?;
    }
    out.flush()?;
    Ok(())
}

fn unseal(src: &Path, dst: &Path) -> std::io::Result<()> {
    let mut f = fs::File::open(src)?;
    let mut head = [0u8; 13];
    f.read_exact(&mut head)?;
    if head[0..4] != MAGIC {
        return Err(std::io::Error::new(ErrorKind::InvalidData, "隔离文件头损坏"));
    }
    let size = u64::from_le_bytes(head[4..12].try_into().unwrap());
    let key = head[12];
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
        // 按记录的原始大小截断，不把多余的加密尾巴写回去
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

    seal(src, &dst, key_for(&id), size).map_err(|e| format!("写入隔离区失败: {e}"))?;
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
        time: now_secs(),
        engine: if engine.is_empty() { "manual".into() } else { engine.to_string() },
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

    if let Err(e) = seal(src, &dst, key_for(&id), size) {
        let _ = fs::remove_file(&dst);
        return fail(buf, len, -3, &format!("写入隔离区失败: {e}"));
    }

    // 原文件删掉 —— 这一步之后，资源管理器里那个目录就看不到它了
    if let Err(e) = fs::remove_file(src) {
        let _ = fs::remove_file(&dst);
        return fail(buf, len, -3, &format!("隔离后删原文件失败（可能被占用）: {e}"));
    }

    let item = QItem {
        id: id.clone(),
        name: src
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default(),
        origin: p.clone(),
        size,
        time: now_secs(),
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
}

/// 列出全部隔离项
#[no_mangle]
pub extern "C" fn quarantine_list(buf: *mut u8, len: usize) -> i32 {
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
}

/// 恢复到原位置（原路径被占用自动加 _restored 后缀，不覆盖）
#[no_mangle]
pub extern "C" fn quarantine_restore(id: *const c_char, buf: *mut u8, len: usize) -> i32 {
    let Some(id) = cstr(id) else {
        return fail(buf, len, -1, "参数为空");
    };
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

    if let Err(e) = unseal(&src, &dst) {
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
}

/// 手动清除单项（彻底删掉，不可恢复）
#[no_mangle]
pub extern "C" fn quarantine_delete(id: *const c_char, buf: *mut u8, len: usize) -> i32 {
    let Some(id) = cstr(id) else {
        return fail(buf, len, -1, "参数为空");
    };
    let mut idx = load_index();
    let exists = idx.iter().any(|i| i.id == id);
    let _ = fs::remove_file(qfile(&id));
    idx.retain(|i| i.id != id);
    save_index(&idx);
    if !exists {
        return fail(buf, len, -3, "隔离库里没有这一项");
    }
    ok(buf, len, "已彻底删除", json!({"id": id, "count": idx.len()}))
}

/// 一键清空
#[no_mangle]
pub extern "C" fn quarantine_clear(buf: *mut u8, len: usize) -> i32 {
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
    ok(buf, len, "隔离库已清空", json!({"removed": removed, "count": 0}))
}
