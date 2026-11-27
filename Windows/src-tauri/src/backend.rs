//! 调用仓库内置的 `reason-network-backend.exe`，并暴露给前端。
//!
//! 客户端不自己实现命名管道协议：所有收发、入网、目录都走后台 CLI，
//! 与 macOS 客户端使用同一条命令路径，历史消息则只读引擎数据库。

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use serde_json::Value;

use crate::store;
use crate::types::{NativeEntry, NetworkSummary, SendOutcome, Snapshot};

/// 后台可执行文件：环境变量优先，其次仓库 `Engine/Bin`，最后在 PATH 里找。
pub fn backend_binary() -> Result<PathBuf, String> {
    if let Some(value) = std::env::var_os("REASON_NETWORK_BIN") {
        let path = PathBuf::from(value);
        if path.is_file() {
            return Ok(path);
        }
        return Err(format!(
            "REASON_NETWORK_BIN 指向的文件不存在：{}",
            path.display()
        ));
    }

    // Windows/src-tauri -> Windows -> 仓库根
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
    if let Some(repo) = manifest.parent().and_then(|path| path.parent()) {
        for candidate in [
            repo.join("Engine").join("Bin").join("reason-network-backend.exe"),
            repo.join("Engine").join("Bin").join("reason-network-backend"),
        ] {
            if candidate.is_file() {
                return Ok(candidate);
            }
        }
    }

    let name = if cfg!(windows) {
        "reason-network.exe"
    } else {
        "reason-network"
    };
    if let Some(paths) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&paths) {
            let candidate = dir.join(name);
            if candidate.is_file() {
                return Ok(candidate);
            }
        }
    }

    Err("未找到 reason-network 后台。请先运行 Engine/build-windows.ps1，或设置 REASON_NETWORK_BIN。".into())
}

fn backend_command(bin: &Path, home: &Path, args: &[&str]) -> Command {
    let mut command = Command::new(bin);
    command
        .args(args)
        .env("REASON_NETWORK_HOME", home)
        .env("REASON_NETWORK_NO_SERVICE", "1")
        .env("REASON_NETWORK_NO_TRAY", "1")
        // 固定测试构建不跟随上游自动更新。
        .env("REASON_NETWORK_NO_UPDATE", "1");
    // 与 macOS 客户端一致：只有工作区 daemon 带 LOCAL_PARTICIPATION。
    if home != store::primary_home().as_path() {
        command.env("REASON_NETWORK_LOCAL_PARTICIPATION", "1");
    }

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // CREATE_NO_WINDOW：不要把后台命令的控制台窗口弹到界面前面。
        command.creation_flags(0x0800_0000);
    }
    command
}

fn check_output(output: Output) -> Result<Output, String> {
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        let detail = if stderr.trim().is_empty() {
            stdout.trim().to_string()
        } else {
            stderr.trim().to_string()
        };
        return Err(if detail.is_empty() {
            format!("后台命令失败（{}）", output.status)
        } else {
            detail
        });
    }
    Ok(output)
}

pub fn run_cli(bin: &Path, home: &Path, args: &[&str]) -> Result<Output, String> {
    let output = backend_command(bin, home, args)
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("启动后台失败：{error}"))?;
    check_output(output)
}

/// 正文走 stdin（CLI 的 `send <to> -`），避免长消息或开头是 `-` 时受命令行限制。
pub fn run_cli_with_input(
    bin: &Path,
    home: &Path,
    args: &[&str],
    input: &str,
) -> Result<Output, String> {
    use std::io::Write;

    let mut child = backend_command(bin, home, args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("启动后台失败：{error}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        // 后台若提前退出会产生 EPIPE；真正的错误由 check_output 从 stderr 读出。
        let _ = stdin.write_all(input.as_bytes());
    }
    let output = child
        .wait_with_output()
        .map_err(|error| format!("等待后台失败：{error}"))?;
    check_output(output)
}

pub fn run_json(home: &Path, args: &[&str]) -> Result<Value, String> {
    let bin = backend_binary()?;
    let output = run_cli(&bin, home, args)?;
    serde_json::from_slice(&output.stdout).map_err(|error| format!("解析后台 JSON 失败：{error}"))
}

#[tauri::command]
pub async fn list_networks() -> Result<Vec<NetworkSummary>, String> {
    let result = tauri::async_runtime::spawn_blocking(store::list_networks)
        .await
        .map_err(|error| error.to_string())?;
    result
}

#[tauri::command]
pub async fn snapshot(
    network: Option<String>,
    local: Option<String>,
    peer: Option<String>,
) -> Result<Snapshot, String> {
    let result = tauri::async_runtime::spawn_blocking(move || {
        let home = store::home_for(network.as_deref())?;
        store::snapshot(&home, local.as_deref(), peer.as_deref())
    })
    .await
    .map_err(|error| error.to_string())?;
    result
}

#[tauri::command]
pub async fn send_message(
    network: Option<String>,
    from: String,
    to: String,
    body: String,
    reply_to: Option<String>,
) -> Result<SendOutcome, String> {
    let result = tauri::async_runtime::spawn_blocking(move || {
        if body.trim().is_empty() {
            return Err("消息不能为空".to_string());
        }
        if from.trim().is_empty() || to.trim().is_empty() {
            return Err("缺少发送或接收会话".to_string());
        }
        let home = store::home_for(network.as_deref())?;
        let bin = backend_binary()?;
        // `send --from <session-key> <to> -`：正文从 stdin 读，与 macOS 客户端一致。
        let mut args = vec!["send".to_string(), "--from".to_string(), from];
        if let Some(reply) = reply_to.filter(|value| !value.is_empty()) {
            args.push("--reply-to".to_string());
            args.push(reply);
        }
        args.push(to);
        args.push("-".to_string());
        let borrowed: Vec<&str> = args.iter().map(String::as_str).collect();
        let output = run_cli_with_input(&bin, &home, &borrowed, &body)?;
        Ok(SendOutcome {
            output: String::from_utf8_lossy(&output.stdout).trim().to_string(),
        })
    })
    .await
    .map_err(|error| error.to_string())?;
    result
}

#[tauri::command]
pub async fn join_network(
    network: Option<String>,
    invite: String,
    person: String,
) -> Result<String, String> {
    let result = tauri::async_runtime::spawn_blocking(move || {
        if invite.trim().is_empty() {
            return Err("请粘贴邀请链接或邀请行".to_string());
        }
        if person.trim().is_empty() {
            return Err("请填写本机名称".to_string());
        }
        let home = store::home_for(network.as_deref())?;
        let bin = backend_binary()?;
        let output = run_cli(
            &bin,
            &home,
            &[
                "join",
                invite.trim(),
                "--as",
                person.trim(),
                "--no-setup",
                "--json",
            ],
        )?;
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    })
    .await
    .map_err(|error| error.to_string())?;
    result
}

#[tauri::command]
pub async fn create_network(
    network: Option<String>,
    name: String,
    person: String,
) -> Result<String, String> {
    let result = tauri::async_runtime::spawn_blocking(move || {
        if name.trim().is_empty() {
            return Err("请填写 Network 名称".to_string());
        }
        if person.trim().is_empty() {
            return Err("请填写本机名称".to_string());
        }
        let home = store::home_for(network.as_deref())?;
        let bin = backend_binary()?;
        let output = run_cli(
            &bin,
            &home,
            &[
                "init",
                name.trim(),
                "--as",
                person.trim(),
                "--no-setup",
                "--json",
            ],
        )?;
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    })
    .await
    .map_err(|error| error.to_string())?;
    result
}

#[tauri::command]
pub async fn native_catalog() -> Result<Vec<NativeEntry>, String> {
    let result = tauri::async_runtime::spawn_blocking(|| {
        let home = store::primary_home();
        let bin = backend_binary()?;
        let output = run_cli(&bin, &home, &["native-session-catalog"])?;
        serde_json::from_slice::<Vec<NativeEntry>>(&output.stdout)
            .map_err(|error| format!("解析本机会话目录失败：{error}"))
    })
    .await
    .map_err(|error| error.to_string())?;
    result
}

#[tauri::command]
pub async fn open_data_folder(network: Option<String>) -> Result<(), String> {
    let home = store::home_for(network.as_deref())?;
    #[cfg(windows)]
    {
        Command::new("explorer")
            .arg(&home)
            .spawn()
            .map_err(|error| format!("打开数据目录失败：{error}"))?;
    }
    #[cfg(not(windows))]
    {
        let _ = &home;
    }
    Ok(())
}
