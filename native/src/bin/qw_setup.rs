#![windows_subsystem = "windows"]
//! 单文件安装器外壳（Rust SFX）：
//! CI 把 Flutter 的 Release 目录打成 payload.zip 追加到本 exe 末尾，
//! 尾部 24 字节是 [offset u64][size u64]["QWPAY1!!"]。
//! 运行后解压到临时目录，再拉起 QWGuard.exe --setup 走 Flutter 安装界面。
use std::env;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::process::Command;

const MAGIC: &[u8; 8] = b"QWPAY1!!";

fn main() {
    if let Err(e) = run() {
        let p = env::temp_dir().join("qw_setup_error.txt");
        let _ = fs::write(p, format!("{e}"));
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let exe = env::current_exe()?;
    let mut f = File::open(&exe)?;
    let len = f.metadata()?.len();
    if len < 1024 {
        return Err("setup 没有附带 payload".into());
    }
    f.seek(SeekFrom::End(-24))?;
    let mut tr = [0u8; 24];
    f.read_exact(&mut tr)?;
    if &tr[16..24] != MAGIC {
        return Err("找不到 payload 标记".into());
    }
    let off = u64::from_le_bytes(tr[0..8].try_into()?);
    let size = u64::from_le_bytes(tr[8..16].try_into()?);

    let tmp = env::temp_dir().join(format!("QWGuardSetup-{}", std::process::id()));
    let _ = fs::remove_dir_all(&tmp);
    fs::create_dir_all(&tmp)?;

    // 先把 payload 切出来存成独立 zip：不能直接对“exe+trailer”开 ZipArchive，
    // 尾部多出 24 字节会让中央目录偏移对不上。
    let zip_path = tmp.join("payload.zip");
    {
        let mut src = File::open(&exe)?;
        src.seek(SeekFrom::Start(off))?;
        let mut take = src.take(size);
        let mut out = File::create(&zip_path)?;
        std::io::copy(&mut take, &mut out)?;
        out.flush()?;
    }

    let mut za = zip::ZipArchive::new(File::open(&zip_path)?)?;
    za.extract(&tmp)?;
    // 这个 170MB 的临时 zip 不能留着：安装器是按“自己所在目录”整目录复制的，
    // 留着会被一起拷进安装目录，白占一份空间。
    let _ = fs::remove_file(&zip_path);

    let setup = tmp.join("QWGuard.exe");
    if !setup.exists() {
        return Err("payload 里没有 QWGuard.exe".into());
    }
    // 自动更新时由主程序带 --silent 拉起：安装向导不显示到前台，
    // 直接把同一套安装流程在后台走完。--dir= 用来覆盖默认推荐目录，
    // 保证覆盖升级装回原来的位置，而不是另装一份。
    let silent = env::args().any(|a| a == "--silent");
    let dir_arg = env::args().find(|a| a.starts_with("--dir="));
    let asset_arg = env::args().find(|a| a.starts_with("--asset-time="));
    let mut cmd = Command::new(&setup);
    cmd.arg("--setup").current_dir(&tmp);
    if silent {
        cmd.arg("--silent");
    }
    if let Some(d) = dir_arg {
        cmd.arg(d);
    }
    if let Some(a) = asset_arg {
        cmd.arg(a);
    }
    cmd.spawn()?;
    Ok(())
}
