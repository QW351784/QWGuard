//! QWGuard MCP 只读服务端。
//!
//! 供 Claude Desktop / Cursor 等支持 Model Context Protocol 的 AI 客户端
//! 通过 stdio 拉起。只暴露「读取状态、硬件、预览、隔离库列表、白名单、
//! 单文件扫描」六类只读工具；不开放删除、隔离、改设置等写操作，
//! 避免 AI 误操作或提示注入把用户文件清掉。
//!
//! 消息格式遵循 MCP stdio：默认一行一条 JSON-RPC；也兼容
//! `Content-Length: N` 的旧式 LSP 分帧，方便不同客户端接入。

#![cfg_attr(windows, windows_subsystem = "windows")]

use serde_json::{json, Value};
use std::ffi::CString;
use std::io::{self, BufRead, BufReader, Write};

const PROTOCOL: &str = "2024-11-05";
const MAX_MSG: usize = 8 * 1024 * 1024;

fn main() {
    if let Err(e) = serve() {
        eprintln!("qw_mcp: {e}");
        std::process::exit(1);
    }
}

fn serve() -> io::Result<()> {
    let stdin = io::stdin();
    let mut reader = BufReader::new(stdin.lock());
    let stdout = io::stdout();
    let mut out = stdout.lock();

    loop {
        let Some(msg) = read_message(&mut reader)? else {
            break;
        };
        let parsed: Value = match serde_json::from_slice(&msg) {
            Ok(v) => v,
            Err(e) => {
                write_msg(
                    &mut out,
                    &json!({
                        "jsonrpc": "2.0",
                        "id": Value::Null,
                        "error": {"code": -32700, "message": format!("JSON 解析失败: {e}")}
                    }),
                )?;
                continue;
            }
        };
        if let Some(resp) = handle(parsed) {
            write_msg(&mut out, &resp)?;
        }
    }
    Ok(())
}

/// 读取一条消息。返回 None 表示 stdin 已关闭。
fn read_message<R: BufRead>(reader: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut first = String::new();
    loop {
        first.clear();
        if reader.read_line(&mut first)? == 0 {
            return Ok(None);
        }
        if !first.trim().is_empty() {
            break;
        }
    }
    let lower = first.to_ascii_lowercase();
    if lower.starts_with("content-length:") {
        let n: usize = first
            .split(':')
            .nth(1)
            .and_then(|s| s.trim().parse().ok())
            .unwrap_or(0);
        if n == 0 || n > MAX_MSG {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "消息长度不合法"));
        }
        // 跳过其余 header，直到空行
        loop {
            let mut h = String::new();
            if reader.read_line(&mut h)? == 0 {
                return Ok(None);
            }
            if h.trim().is_empty() {
                break;
            }
        }
        let mut buf = vec![0u8; n];
        reader.read_exact(&mut buf)?;
        return Ok(Some(buf));
    }
    if first.len() > MAX_MSG {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "消息过长"));
    }
    Ok(Some(first.into_bytes()))
}

fn write_msg<W: Write>(out: &mut W, v: &Value) -> io::Result<()> {
    serde_json::to_writer(&mut *out, v)?;
    out.write_all(b"\n")?;
    out.flush()
}

fn handle(req: Value) -> Option<Value> {
    let id = req.get("id").cloned().unwrap_or(Value::Null);
    let method = req.get("method").and_then(|m| m.as_str()).unwrap_or("");
    // 通知没有 id，按 MCP 规范不回包
    let is_notification = req.get("id").is_none();

    if is_notification {
        return None;
    }

    let result = match method {
        "initialize" => Ok(json!({
            "protocolVersion": PROTOCOL,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "qwguard-mcp", "version": "1.1.0"},
            "instructions": "QWGuard 只读 MCP。可读取安全状态、硬件指标、清理预览、隔离库、白名单，并扫描单个文件；不会删除文件或修改设置。"
        })),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({"tools": tool_defs()})),
        "tools/call" => call_tool(req.get("params").cloned().unwrap_or(Value::Null)),
        _ => Err((-32601, format!("未知方法: {method}"))),
    };

    Some(match result {
        Ok(r) => json!({"jsonrpc": "2.0", "id": id, "result": r}),
        Err((code, message)) => json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": {"code": code, "message": message}
        }),
    })
}

fn tool_defs() -> Value {
    json!([
        {
            "name": "qwguard_status",
            "description": "读取 QWGuard 的安全设置：密码保护、严格模式、查杀性能模式、后台清理/查杀频率、发现病毒处理方式、信任目录数量。只读，不修改任何设置。",
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}
        },
        {
            "name": "qwguard_hardware",
            "description": "读取当前硬件实时指标：CPU、内存、磁盘、温度等。只读。",
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}
        },
        {
            "name": "qwguard_cleanup_preview",
            "description": "预览可清理的垃圾文件与预计释放空间。只扫描预览，不删除任何文件。",
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}
        },
        {
            "name": "qwguard_quarantine_list",
            "description": "列出隔离库中的项目（编号、原路径、大小、威胁名、隔离时间）。只读。",
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}
        },
        {
            "name": "qwguard_whitelist_list",
            "description": "列出扫描白名单/信任区路径。只读。",
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}
        },
        {
            "name": "qwguard_scan_file",
            "description": "用本机引擎扫描单个文件并返回威胁结果。只读扫描，不会隔离或删除文件。",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "要扫描的文件的绝对路径"},
                    "engine": {
                        "type": "string",
                        "enum": ["signature", "heuristic", "yara", "defender"],
                        "description": "扫描引擎，默认 signature"
                    }
                },
                "required": ["path"],
                "additionalProperties": false
            }
        }
    ])
}

fn call_tool(params: Value) -> Result<Value, (i32, String)> {
    let name = params.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let args = params
        .get("arguments")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let result = match name {
        "qwguard_status" => {
            ffi_call(|buf, len| toolkit_native::security::security_settings(buf, len))
        }
        "qwguard_hardware" => ffi_call(|buf, len| toolkit_native::get_hardware_metrics(buf, len)),
        "qwguard_cleanup_preview" => ffi_call(|buf, len| toolkit_native::scan_cleanup(buf, len)),
        "qwguard_quarantine_list" => {
            ffi_call(|buf, len| toolkit_native::quarantine::quarantine_list(buf, len))
        }
        "qwguard_whitelist_list" => {
            ffi_call(|buf, len| toolkit_native::ext::whitelist_list(buf, len))
        }
        "qwguard_scan_file" => scan_file(&args),
        _ => return Err((-32602, format!("未知工具: {name}"))),
    };
    let is_error = result.get("success").and_then(|v| v.as_bool()) == Some(false);
    Ok(json!({
        "content": [{"type": "text", "text": serde_json::to_string_pretty(&result).unwrap_or_else(|_| "{}".into())}],
        "isError": is_error
    }))
}

fn scan_file(args: &Value) -> Value {
    let path = match args.get("path").and_then(|v| v.as_str()) {
        Some(p) if !p.trim().is_empty() => p,
        _ => return json!({"success": false, "message": "path 不能为空"}),
    };
    let engine = args
        .get("engine")
        .and_then(|v| v.as_str())
        .unwrap_or("signature");
    if !matches!(engine, "signature" | "heuristic" | "yara" | "defender") {
        return json!({"success": false, "message": "engine 只支持 signature/heuristic/yara/defender"});
    }
    let (Ok(e), Ok(p)) = (CString::new(engine), CString::new(path)) else {
        return json!({"success": false, "message": "路径包含非法字符"});
    };
    ffi_call(|buf, len| toolkit_native::scan_file(e.as_ptr(), p.as_ptr(), buf, len))
}

/// 统一调用 FFI：函数把 JSON 写进 buf，返回码 0 表示成功。
fn ffi_call<F: FnOnce(*mut u8, usize) -> i32>(f: F) -> Value {
    let mut buf = vec![0u8; 4 * 1024 * 1024];
    let rc = f(buf.as_mut_ptr(), buf.len());
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    match serde_json::from_slice::<Value>(&buf[..end]) {
        Ok(v) => v,
        Err(e) => json!({
            "success": false,
            "message": format!("原生层返回无法解析（rc={rc}）: {e}")
        }),
    }
}
