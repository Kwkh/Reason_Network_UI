//! 调用仓库内置的 `reason-network-backend.exe`，并暴露给前端。
//!
//! 客户端不自己实现命名管道协议：所有收发、入网、目录都走后台 CLI，
//! 与 macOS 客户端使用同一条命令路径，历史消息则只读引擎数据库。

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::attachments;
use crate::daemon_ipc;
use crate::store;
use crate::types::{
    AttachmentDraft, BackendInfo, JoinResult, NativeEntry, NetworkSummary, ParticipationBatch,
    ParticipationFailure, SendOutcome, Snapshot,
};

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

/// 带超时的 CLI 调用：`leave` 需要等在线的队友确认，不能无限阻塞界面。
fn run_cli_timeout(bin: &Path, home: &Path, args: &[&str], limit: Duration) -> Result<Output, String> {
    let mut child = backend_command(bin, home, args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("启动后台失败：{error}"))?;
    let started = Instant::now();
    loop {
        match child.try_wait().map_err(|error| error.to_string())? {
            Some(status) => {
                let mut stdout = Vec::new();
                let mut stderr = Vec::new();
                if let Some(mut out) = child.stdout.take() {
                    let _ = out.read_to_end(&mut stdout);
                }
                if let Some(mut err) = child.stderr.take() {
                    let _ = err.read_to_end(&mut stderr);
                }
                return check_output(Output {
                    status,
                    stdout,
                    stderr,
                });
            }
            None if started.elapsed() >= limit => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("后台操作超时，请检查网络后重试。".into());
            }
            None => std::thread::sleep(Duration::from_millis(100)),
        }
    }
}

pub fn run_json(home: &Path, args: &[&str]) -> Result<Value, String> {    let bin = backend_binary()?;
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
            team_id: Some(id.clone()),
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

/// 删除一个独立工作区：先结束它自己的 daemon（SQLite 被占用时目录删不掉），
/// 再删掉本机目录。主工作区、`~/.reason` 其它数据和工作区目录之外的内容都不动。
#[tauri::command]
pub async fn delete_workspace(id: String) -> Result<(), String> {
    let dir = store::workspace_dir_for(&id)?;
    tauri::async_runtime::spawn_blocking(move || -> Result<(), String> {
        let mut last = String::new();
        // 客户端的轮询可能在第一次结束 daemon 后马上又把它拉起来，所以重试几次；
        // 每次重试都重新按 daemon.lock 结束进程。
        for attempt in 0..10u32 {
            stop_daemon_process(&dir);
            match std::fs::remove_dir_all(&dir) {
                Ok(()) => return Ok(()),
                Err(error) => last = error.to_string(),
            }
            if attempt >= 3 {
                std::thread::sleep(std::time::Duration::from_millis(400));
            } else {
                std::thread::sleep(std::time::Duration::from_millis(200));
            }
        }
        Err(format!(
            "删除工作区失败：{last}。请关闭正在使用该工作区的程序后重试。"
        ))
    })
    .await
    .map_err(|error| error.to_string())?
}

/// 能接入工作区的原生 agent，与上游 `agent::workspace_agent` 保持一致。
const NATIVE_AGENTS: [&str; 4] = ["codex", "claude-code", "gemini", "dsh"];

fn native_session_payload(key: &str, agent: &str, name: &str, cwd: &str) -> Result<Value, String> {
    if !NATIVE_AGENTS.contains(&agent) {
        return Err(
            "只有原生 agent 会话（Codex、Claude Code、Gemini CLI、dsh）可以接入 Network。".into(),
        );
    }
    let id = key
        .strip_prefix(&format!("{agent}:"))
        .filter(|id| !id.is_empty() && id.len() <= 512 && !id.chars().any(char::is_control))
        .ok_or_else(|| "会话标识不完整，无法接入 Network。".to_string())?;
    Ok(serde_json::json!({
        "key": key,
        "agent": agent,
        "cwd": cwd,
        "agent_session_id": id,
        "tier": "pull",
        "name": name,
    }))
}

fn friendly_join_error(error: String) -> String {
    let text = error.trim().trim_start_matches("Error: ");
    let mapped = if text.contains("has not joined the requested Network") {
        "本机还没有加入这个 Network。"
    } else if text.contains("More than one workspace matches") {
        "有同名 Network，请刷新后选择唯一 ID。"
    } else if text.contains("native identity for the calling conversation") {
        "只有原生 agent 会话（Codex、Claude Code、Gemini CLI、dsh）可以接入 Network。"
    } else if text.contains("Codex thread is archived") {
        "这个 Codex 线程已归档或不可用，请打开原对话后重试。"
    } else if text.contains("disconnected during join") {
        "会话在接入过程中被暂停，请恢复后重试。"
    } else if text.contains("Network membership changed") {
        "Network 状态已变化，请刷新后重试。"
    } else {
        return format!("接入 Network 失败：{text}");
    };
    mapped.to_string()
}

/// 把一个本机会话接入指定 Network（主工作区或独立工作区）。
///
/// 只把请求发给主工作区 daemon：它按 team id 找到对应工作区，再转发过去。
#[tauri::command]
pub async fn join_session_network(
    key: String,
    agent: String,
    name: String,
    cwd: String,
    target: String,
) -> Result<JoinResult, String> {
    let session = native_session_payload(&key, &agent, &name, &cwd)?;
    let target = target.trim();
    if target.is_empty() {
        return Err("请选择要接入的 Network。".into());
    }
    let primary = store::primary_home();
    ensure_daemon(primary.clone()).await?;
    let value = daemon_ipc::request(
        &primary,
        serde_json::json!({ "op": "join_current_session", "network": target, "session": session }),
    )
    .await
    .map_err(friendly_join_error)?;
    Ok(JoinResult {
        network_id: value
            .get("network_id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        network_name: value
            .get("network_name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        address: value
            .get("address")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        online: value.get("online").and_then(Value::as_bool).unwrap_or(false),
    })
}

fn friendly_admin_error(error: String) -> String {
    let text = error.trim().trim_start_matches("Error: ");
    if text.contains("founder") && (text.contains("only") || text.contains("not")) {
        "只有 Network 创建者可以执行这个操作。".into()
    } else if text.contains("no teammate is online") {
        "当前没有在线队友可以接收退出通知；等队友上线后再试。".into()
    } else if text.contains("not in a team") || text.contains("No Network") {
        "这台机器还没有加入这个 Network。".into()
    } else {
        format!("操作失败：{text}")
    }
}

/// 一次性邀请码（四词代码，默认 24 小时有效）。
#[tauri::command]
pub async fn invite_code(network: Option<String>) -> Result<String, String> {
    let home = store::home_for(network.as_deref())?;
    if store::team_id(&home)?.is_none() {
        return Err("这台机器还没有加入这个 Network。".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let bin = backend_binary()?;
        let output = run_cli(&bin, &home, &["invite", "--code"])?;
        let text = String::from_utf8_lossy(&output.stdout);
        let code = text
            .lines()
            .find_map(|line| line.split_once("code for a teammate:").map(|(_, rest)| rest.trim()))
            .filter(|code| !code.is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| text.trim().to_string());
        if code.is_empty() {
            return Err("后台没有返回邀请码。".into());
        }
        Ok(code)
    })
    .await
    .map_err(|error| error.to_string())?
}

/// 退出当前 Network（工作区或主工作区）。没有在线队友时后台会拒绝，可等队友上线。
#[tauri::command]
pub async fn leave_network(network: Option<String>, force: bool) -> Result<(), String> {
    let home = store::home_for(network.as_deref())?;
    if store::team_id(&home)?.is_none() {
        return Err("这台机器还没有加入这个 Network。".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let bin = backend_binary()?;
        let args: &[&str] = if force { &["leave", "--force"] } else { &["leave"] };
        run_cli_timeout(&bin, &home, args, Duration::from_secs(45)).map_err(friendly_admin_error)?;
        if store::team_id(&home)?.is_some() {
            return Err("后台还没有确认退出，请刷新后重试。".into());
        }
        Ok(())
    })
    .await
    .map_err(|error| error.to_string())?
}

/// 解散 Network（仅创建者）。等 daemon 清掉本地团队状态后再返回。
#[tauri::command]
pub async fn dissolve_network(network: Option<String>) -> Result<(), String> {
    let home = store::home_for(network.as_deref())?;
    let team = store::team_id(&home)?.ok_or_else(|| "这台机器还没有加入这个 Network。".to_string())?;
    ensure_daemon(home.clone()).await?;
    daemon_ipc::request(
        &home,
        serde_json::json!({ "op": "dissolve_network", "network": team }),
    )
    .await
    .map_err(friendly_admin_error)?;
    for _ in 0..40 {
        if store::team_id(&home)?.is_none() {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    Err("后台还没有确认解散，请刷新后重试。".into())
}

/// 移除一台设备（仅创建者）。
#[tauri::command]
pub async fn remove_device(network: Option<String>, endpoint: String) -> Result<(), String> {
    let endpoint = endpoint.trim().to_string();
    if endpoint.is_empty() {
        return Err("设备标识为空。".into());
    }
    let home = store::home_for(network.as_deref())?;
    let team = store::team_id(&home)?.ok_or_else(|| "这台机器还没有加入这个 Network。".to_string())?;
    ensure_daemon(home.clone()).await?;
    daemon_ipc::request(
        &home,
        serde_json::json!({ "op": "remove_device", "network": team, "endpoint": endpoint }),
    )
    .await
    .map_err(friendly_admin_error)?;
    Ok(())
}

/// 设置本机会话的接收模式：push（即时推送）/ turn（回合接收）/ pull（手动收件）。
#[tauri::command]
pub async fn set_receive_mode(
    network: Option<String>,
    key: String,
    mode: String,
) -> Result<(), String> {
    if !matches!(mode.as_str(), "push" | "turn" | "pull") {
        return Err("接收模式不合法。".into());
    }
    let home = store::home_for(network.as_deref())?;
    let team = store::team_id(&home)?.ok_or_else(|| "这台机器还没有加入这个 Network。".to_string())?;
    ensure_daemon(home.clone()).await?;
    daemon_ipc::request(
        &home,
        serde_json::json!({ "op": "set_receive_mode", "key": key, "network": team, "mode": mode }),
    )
    .await
    .map_err(|error| {
        let text = error.trim().trim_start_matches("Error: ");
        if text.contains("该会话不支持此接收模式") {
            "这个会话不支持所选的接收模式。".into()
        } else if text.contains("尚未建立回合接收通道") {
            "这个会话还没有可用的回合接收通道，请先让它在工具里运行一个回合。".into()
        } else {
            format!("设置接收模式失败：{text}")
        }
    })?;
    Ok(())
}

/// 批量暂停或恢复本机会话，逐项返回失败原因。
#[tauri::command]
pub async fn set_sessions_participation(
    network: Option<String>,
    keys: Vec<String>,
    paused: bool,
) -> Result<ParticipationBatch, String> {
    let home = store::home_for(network.as_deref())?;
    if keys.is_empty() {
        return Ok(ParticipationBatch {
            changed: 0,
            failures: Vec::new(),
        });
    }
    ensure_daemon(home.clone()).await?;
    let mut changed = 0usize;
    let mut failures = Vec::new();
    for key in keys {
        let result = daemon_ipc::request(
            &home,
            serde_json::json!({ "op": "set_session_participation", "key": key, "paused": paused }),
        )
        .await;
        match result {
            Ok(_) => changed += 1,
            Err(error) => failures.push(ParticipationFailure { key, error }),
        }
    }
    Ok(ParticipationBatch { changed, failures })
}

#[tauri::command]
pub async fn list_networks() -> Result<Vec<NetworkSummary>, String> {    let result = tauri::async_runtime::spawn_blocking(store::list_networks)
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

/// 配置类命令不设置 REASON_NETWORK_NO_SERVICE：是否安装服务由 `--no-service` 决定。
fn setup_command(bin: &Path, home: &Path) -> Command {
    let mut command = Command::new(bin);
    command
        .env("REASON_NETWORK_HOME", home)
        .env("REASON_NETWORK_NO_TRAY", "1")
        .env("REASON_NETWORK_NO_UPDATE", "1");
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000);
    }
    command
}

fn run_setup(home: &Path, args: &[&str]) -> Result<String, String> {
    let bin = backend_binary()?;
    let output = setup_command(&bin, home)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("启动后台失败：{error}"))?;
    let stdout = String::from_utf8_lossy(&output.stdout).trim_end().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim_end().to_string();
    if !output.status.success() {
        let detail = if stderr.trim().is_empty() {
            stdout
        } else {
            stderr
        };
        let detail = detail.trim().strip_prefix("Error: ").unwrap_or(detail.trim());
        return Err(if detail.is_empty() {
            format!("后台命令失败（{}）", output.status)
        } else {
            detail.to_string()
        });
    }
    let mut text = stdout;
    if !stderr.trim().is_empty() {
        if !text.is_empty() {
            text.push('\n');
        }
        text.push_str(&stderr);
    }
    Ok(text)
}

fn backend_source(path: &Path) -> String {
    if std::env::var_os("REASON_NETWORK_BIN")
        .map(PathBuf::from)
        .as_deref()
        == Some(path)
    {
        return "环境变量".into();
    }
    if bundled_binary().as_deref() == Some(path) {
        return "安装包内置".into();
    }
    if let Some(repo) = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
    {
        if repo.join("Engine").join("Bin").join("reason-network-backend.exe") == path {
            return "仓库构建".into();
        }
    }
    "PATH".into()
}

#[tauri::command]
pub async fn backend_info() -> Result<BackendInfo, String> {
    let result = tauri::async_runtime::spawn_blocking(|| {
        let path = backend_binary()?;
        let output = Command::new(&path)
            .arg("--version")
            .stdin(Stdio::null())
            .output()
            .map_err(|error| format!("无法运行后台：{error}"))?;
        if !output.status.success() {
            return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
        }
        Ok(BackendInfo {
            path: path.to_string_lossy().to_string(),
            version: String::from_utf8_lossy(&output.stdout).trim().to_string(),
            source: backend_source(&path),
        })
    })
    .await
    .map_err(|error| error.to_string())?;
    result
}

#[tauri::command]
pub async fn app_integrations() -> Result<Vec<String>, String> {
    let result = tauri::async_runtime::spawn_blocking(|| {
        let home = store::primary_home();
        let bin = backend_binary()?;
        let bin_text = bin.to_string_lossy().to_string();
        // 与 macOS 一致：把后台路径作为可执行文件传给 app-integrations，
        // 否则它只报到“正在使用”的工具，可能返回空数组。
        let text = run_setup(&home, &["app-integrations", &bin_text])?;
        serde_json::from_str::<Vec<String>>(&text)
            .map_err(|error| format!("解析工具列表失败：{error}（{text}）"))
    })
    .await
    .map_err(|error| error.to_string())?;
    result
}

#[tauri::command]
pub async fn setup_preview() -> Result<String, String> {
    let result = tauri::async_runtime::spawn_blocking(|| {
        run_setup(&store::primary_home(), &["setup", "--dry-run"])
    })
    .await
    .map_err(|error| error.to_string())?;
    result
}

#[tauri::command]
pub async fn setup_configure() -> Result<String, String> {
    let result = tauri::async_runtime::spawn_blocking(|| {
        run_setup(&store::primary_home(), &["setup", "--no-service"])
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

#[cfg(test)]
mod tests {
    use super::native_session_payload;

    #[test]
    fn join_payload_requires_native_agent() {
        assert!(native_session_payload("cli:probe", "cli", "probe", "/tmp").is_err());
        assert!(native_session_payload("claude-code:probe", "claude-code", "probe", "/tmp").is_ok());
    }

    #[test]
    fn join_payload_checks_key_shape() {
        assert!(native_session_payload("codex:", "codex", "probe", "/tmp").is_err());
        assert!(native_session_payload("codex:abc", "claude-code", "probe", "/tmp").is_err());
        assert!(native_session_payload("codex:abc", "codex", "probe", "/tmp").is_ok());
    }
}
