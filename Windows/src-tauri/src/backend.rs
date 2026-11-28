//! 调用仓库内置的 `reason-network-backend.exe`，并暴露给前端。
//!
//! 客户端不自己实现命名管道协议：所有收发、入网、目录都走后台 CLI，
//! 与 macOS 客户端使用同一条命令路径，历史消息则只读引擎数据库。

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::OnceLock;

use serde_json::Value;

use crate::attachments;
use crate::daemon_ipc;
use crate::store;
use crate::types::{AttachmentDraft, NativeEntry, NetworkSummary, SendOutcome, Snapshot};

/// 安装包内置的后台路径；由 `setup` 在启动时解析资源目录后写入。
static BUNDLED_BINARY: OnceLock<Option<PathBuf>> = OnceLock::new();

pub fn set_bundled_binary(path: Option<PathBuf>) {
    let _ = BUNDLED_BINARY.set(path);
}

fn bundled_binary() -> Option<PathBuf> {
    BUNDLED_BINARY.get().and_then(|path| path.clone())
}

/// 后台可执行文件：环境变量优先，其次安装包内置资源、仓库 `Engine/Bin`，最后在 PATH 里找。
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

    if let Some(candidate) = bundled_binary().filter(|path| path.is_file()) {
        return Ok(candidate);
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
        // CLI 的错误行自带 `Error: ` 前缀，界面里去掉更干净。
        let detail = detail.strip_prefix("Error: ").unwrap_or(&detail).to_string();
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

/// 先跑一次 CLI，让按需启动的 daemon 起来，再走命名管道。
async fn ensure_daemon(home: PathBuf) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        let bin = backend_binary()?;
        run_cli(&bin, &home, &["team", "--json"]).map(|_| ())
    })
    .await
    .map_err(|error| error.to_string())?
}

#[tauri::command]
pub async fn set_session_participation(
    network: Option<String>,
    key: String,
    paused: bool,
) -> Result<(), String> {
    if key.trim().is_empty() {
        return Err("缺少本机会话".into());
    }
    let home = store::home_for(network.as_deref())?;
    ensure_daemon(home.clone()).await?;
    daemon_ipc::request(
        &home,
        serde_json::json!({
            "op": "set_session_participation",
            "key": key,
            "paused": paused,
        }),
    )
    .await?;
    // 与 macOS 一致：回读一次，确认 daemon 真的接受了状态。
    let state = daemon_ipc::request(&home, serde_json::json!({ "op": "session_participation" })).await?;
    let confirmed = state
        .get("paused")
        .and_then(Value::as_array)
        .map(|items| items.iter().any(|item| item.as_str() == Some(key.as_str())))
        .unwrap_or(false);
    if confirmed != paused {
        return Err("后台没有确认会话状态，请刷新后重试。".into());
    }
    Ok(())
}

#[tauri::command]
pub async fn enable_workspaces(network: Option<String>) -> Result<(), String> {
    let home = store::home_for(network.as_deref())?;
    ensure_daemon(home.clone()).await?;
    daemon_ipc::request(&home, serde_json::json!({ "op": "enable_workspaces" })).await?;
    Ok(())
}

/// 加入失败时 daemon 可能已经起来并占着数据库；先结束它，才能删掉半成品目录。
fn stop_daemon_process(home: &Path) {
    #[cfg(windows)]
    {
        use windows_sys::Win32::Foundation::CloseHandle;
        use windows_sys::Win32::System::Threading::{
            OpenProcess, TerminateProcess, PROCESS_TERMINATE,
        };
        let pid = std::fs::read_to_string(home.join("daemon.lock"))
            .ok()
            .and_then(|text| text.trim().parse::<u32>().ok());
        if let Some(pid) = pid {
            // SAFETY: 只用 PROCESS_TERMINATE 打开 daemon.lock 记录的 PID。
            unsafe {
                let handle = OpenProcess(PROCESS_TERMINATE, 0, pid);
                if !handle.is_null() {
                    let _ = TerminateProcess(handle, 1);
                    let _ = CloseHandle(handle);
                }
            }
            for _ in 0..20 {
                if !home.join("daemon.lock").exists() {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
        }
    }
    #[cfg(not(windows))]
    let _ = home;
}

fn friendly_workspace_error(error: String) -> String {
    let text = error.trim();
    let text = text.strip_prefix("Error: ").unwrap_or(text);
    if text.contains("\"name_taken\"") {
        return "这台机器上已有同名身份，请换一个本机名称后再试。".into();
    }
    if let Ok(value) = serde_json::from_str::<Value>(text) {
        if let Some(code) = value.get("error").and_then(Value::as_str) {
            return format!("加入失败：{code}");
        }
    }
    text.to_string()
}

fn new_workspace_name() -> String {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_nanos())
        .unwrap_or_default();
    format!("{stamp:032x}")
}

/// 在主工作区启用工作区分发，然后在 `~/.reason/workspaces/<新目录>` 里建网或入网。
async fn provision_workspace(
    name: String,
    person: String,
    invite: Option<String>,
) -> Result<NetworkSummary, String> {
    let person = person.trim().to_string();
    if person.is_empty() {
        return Err("请填写本机名称".into());
    }
    let name = name.trim().to_string();
    let invite = invite
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    if invite.is_none() {
        if name.is_empty() {
            return Err("请填写 Network 名称".into());
        }
        if name.chars().count() > 60 {
            return Err("Network 名称最多 60 字".into());
        }
    }

    let primary = store::primary_home();
    ensure_daemon(primary.clone()).await?;
    daemon_ipc::request(&primary, serde_json::json!({ "op": "enable_workspaces" })).await?;

    let task_person = person.clone();
    tauri::async_runtime::spawn_blocking(move || -> Result<NetworkSummary, String> {
        let bin = backend_binary()?;
        let root = store::workspaces_root();
        std::fs::create_dir_all(&root).map_err(|error| format!("创建工作区目录失败：{error}"))?;
        let mut dir = root.join(new_workspace_name());
        while dir.exists() {
            dir = root.join(new_workspace_name());
        }
        std::fs::create_dir_all(&dir).map_err(|error| format!("创建工作区目录失败：{error}"))?;

        let args: Vec<String> = match &invite {
            Some(ticket) => vec![
                "join".into(),
                ticket.clone(),
                "--as".into(),
                task_person.clone(),
                "--no-setup".into(),
                "--json".into(),
            ],
            None => vec![
                "init".into(),
                name.clone(),
                "--as".into(),
                task_person.clone(),
                "--no-setup".into(),
                "--json".into(),
            ],
        };
        let borrowed: Vec<&str> = args.iter().map(String::as_str).collect();
        let output = match run_cli(&bin, &dir, &borrowed) {
            Ok(output) => output,
            Err(error) => {
                // 新建/加入失败时不要留下半成品工作区目录。
                stop_daemon_process(&dir);
                let _ = std::fs::remove_dir_all(&dir);
                return Err(friendly_workspace_error(error));
            }
        };
        let value: Value = serde_json::from_slice(&output.stdout)
            .map_err(|error| format!("解析后台 JSON 失败：{error}"))?;
        let id = value
            .get("team_id")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| "后台没有返回 Network id".to_string())?
            .to_string();
        let team_name = value
            .get("team_name")
            .and_then(Value::as_str)
            .unwrap_or("Network")
            .to_string();
        std::fs::write(dir.join("workspace-id"), &id)
            .map_err(|error| format!("写入工作区标识失败：{error}"))?;
        // init/join 会重启 daemon；顺手拉起并等它就绪。
        let _ = run_json(&dir, &["team", "--json"]);
        Ok(NetworkSummary {
            id,
            name: team_name,
            person: task_person,
            machine: String::new(),
            joined: true,
            primary: false,
        })
    })
    .await
    .map_err(|error| error.to_string())?
}

#[tauri::command]
pub async fn create_workspace(name: String, person: String) -> Result<NetworkSummary, String> {
    provision_workspace(name, person, None).await
}

#[tauri::command]
pub async fn join_workspace(invite: String, person: String) -> Result<NetworkSummary, String> {
    provision_workspace(String::new(), person, Some(invite)).await
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
    files: Option<Vec<String>>,
    notify: Option<bool>,
) -> Result<SendOutcome, String> {
    let result = tauri::async_runtime::spawn_blocking(move || {
        if from.trim().is_empty() || to.trim().is_empty() {
            return Err("缺少发送或接收会话".to_string());
        }
        let files = files.unwrap_or_default();
        // 发送前再校验一次：附件可能在选择后被改动。
        let drafts = attachments::inspect(&files)?;
        let typed = body.trim();
        let content = if typed.is_empty() && !drafts.is_empty() {
            "附件".to_string()
        } else {
            typed.to_string()
        };
        if content.is_empty() {
            return Err("消息不能为空".to_string());
        }
        if content.chars().count() > 10_000 {
            return Err("请输入 1–10000 字的消息".to_string());
        }
        let home = store::home_for(network.as_deref())?;
        let bin = backend_binary()?;
        // `send --from <session-key> [--notify] [--file <path>]... <to> -`：
        // 正文从 stdin 读，参数顺序与 macOS 客户端一致。
        let mut args = vec!["send".to_string(), "--from".to_string(), from];
        if notify.unwrap_or(false) {
            args.push("--notify".to_string());
        }
        for draft in &drafts {
            args.push("--file".to_string());
            args.push(draft.path.clone());
        }
        if let Some(reply) = reply_to.filter(|value| !value.is_empty()) {
            args.push("--reply-to".to_string());
            args.push(reply);
        }
        args.push(to);
        args.push("-".to_string());
        let borrowed: Vec<&str> = args.iter().map(String::as_str).collect();
        let output = run_cli_with_input(&bin, &home, &borrowed, &content)?;
        Ok(SendOutcome {
            output: String::from_utf8_lossy(&output.stdout).trim().to_string(),
        })
    })
    .await
    .map_err(|error| error.to_string())?;
    result
}

#[tauri::command]
pub async fn inspect_attachments(paths: Vec<String>) -> Result<Vec<AttachmentDraft>, String> {
    let result = tauri::async_runtime::spawn_blocking(move || attachments::inspect(&paths))
        .await
        .map_err(|error| error.to_string())?;
    result
}

#[tauri::command]
pub async fn attachment_text(
    network: Option<String>,
    directory: String,
    name: String,
) -> Result<String, String> {
    let result = tauri::async_runtime::spawn_blocking(move || {
        let home = store::home_for(network.as_deref())?;
        attachments::read_attachment(&home, &directory, &name)
    })
    .await
    .map_err(|error| error.to_string())?;
    result
}

#[tauri::command]
pub async fn save_attachment(
    network: Option<String>,
    directory: String,
    name: String,
    target: String,
) -> Result<(), String> {
    let result = tauri::async_runtime::spawn_blocking(move || {
        let home = store::home_for(network.as_deref())?;
        attachments::save_attachment(&home, &directory, &name, &target)
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
pub async fn network_link(network: Option<String>) -> Result<String, String> {
    let result = tauri::async_runtime::spawn_blocking(move || {
        let home = store::home_for(network.as_deref())?;
        let value = run_json(&home, &["link", "--json"])?;
        value
            .get("link")
            .and_then(Value::as_str)
            .filter(|link| !link.is_empty())
            .map(str::to_string)
            .ok_or_else(|| "后台没有返回邀请链接".to_string())
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
