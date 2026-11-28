//! 通过引擎的命名管道调用会话控制操作。
//!
//! 暂停/恢复接入、启用工作区这类操作只存在于 daemon 协议里，没有 CLI 子命令。
//! 这里复用上游的管道命名规则（FNV-1a(home)）直接发一行 JSON，并校验管道
//! 对端 PID 与 `daemon.lock` 一致，避免连到同名的其他进程。

use std::path::Path;
use std::time::Duration;

use serde_json::Value;

/// 向 `home` 对应的 daemon 发一条请求，返回 `result`。后台错误会原样返回。
#[cfg(windows)]
pub async fn request(home: &Path, payload: Value) -> Result<Value, String> {
    use std::os::windows::io::AsRawHandle;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::net::windows::named_pipe::ClientOptions;

    let path = pipe_path(home);
    let mut tries = 0u32;
    let pipe = loop {
        match ClientOptions::new().open(&path) {
            // 每个连接会短暂占满一个管道实例，稍后重试。
            Err(error) if error.raw_os_error() == Some(231) && tries < 40 => {
                tries += 1;
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
            Err(error) => return Err(format!("连接本机后台失败：{error}")),
            Ok(pipe) => break pipe,
        }
    };

    let mut server = 0u32;
    // SAFETY: 查询的是刚打开的这个管道句柄。
    unsafe {
        windows_sys::Win32::System::Pipes::GetNamedPipeServerProcessId(
            pipe.as_raw_handle(),
            &mut server,
        );
    }
    let expected = std::fs::read_to_string(home.join("daemon.lock"))
        .ok()
        .and_then(|text| text.trim().parse::<u32>().ok());
    if expected != Some(server) {
        return Err("连接到的不是本机的 Reason Network 后台".into());
    }

    let mut payload = payload;
    payload["id"] = Value::from(1);
    let line = serde_json::to_string(&payload)
        .map_err(|error| format!("编码后台请求失败：{error}"))?
        + "\n";
    let mut reader = BufReader::new(pipe);
    let call = async {
        reader
            .get_mut()
            .write_all(line.as_bytes())
            .await
            .map_err(|error| format!("发送后台请求失败：{error}"))?;
        let mut reply = String::new();
        reader
            .read_line(&mut reply)
            .await
            .map_err(|error| format!("读取后台响应失败：{error}"))?;
        Ok::<String, String>(reply)
    };
    let reply = tokio::time::timeout(Duration::from_secs(10), call)
        .await
        .map_err(|_| "本机后台没有及时响应，请稍后重试。".to_string())??;
    let reply: Value = serde_json::from_str(reply.trim())
        .map_err(|error| format!("解析后台响应失败：{error}"))?;
    if reply.get("ok").and_then(Value::as_bool) != Some(true) {
        let message = reply
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("后台操作失败");
        return Err(message.to_string());
    }
    Ok(reply.get("result").cloned().unwrap_or(Value::Null))
}

#[cfg(windows)]
fn pipe_path(home: &Path) -> std::path::PathBuf {
    let dir = home
        .canonicalize()
        .unwrap_or_else(|_| home.to_path_buf());
    let dir = dir
        .to_str()
        .and_then(|text| text.strip_prefix(r"\\?\"))
        .map_or(dir.clone(), std::path::PathBuf::from);
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for byte in dir.as_os_str().as_encoded_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100_0000_01b3);
    }
    std::path::PathBuf::from(format!(r"\\.\pipe\reason-network-{hash:016x}"))
}

#[cfg(not(windows))]
pub async fn request(_home: &Path, _payload: Value) -> Result<Value, String> {
    Err("仅 Windows 支持本机会话控制".into())
}
