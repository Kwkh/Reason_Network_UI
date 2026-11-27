//! 只读读取 Reason 引擎数据库，并对后台 JSON 输出做轻量解析。
//!
//! 引擎数据库由后台独占写入；桌面端只读打开 `network.db`，不改动收件箱、
//! 已读状态或投递队列。消息正文只从 `messages` / `workspace_sent` 读取。

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde_json::Value;

use crate::backend::run_json;
use crate::types::{
    Attachment, ChatMessage, Conversation, DirectorySession, LocalSession, Member, NetworkSummary,
    Snapshot,
};

pub fn user_home() -> PathBuf {
    std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

pub fn primary_home() -> PathBuf {
    user_home().join(".reason").join("network")
}

pub fn workspaces_root() -> PathBuf {
    user_home().join(".reason").join("workspaces")
}

/// `None`/`primary` 表示主工作区，其余是 `~/.reason/workspaces/<id>` 的目录名。
pub fn home_for(network: Option<&str>) -> Result<PathBuf, String> {
    match network {
        None | Some("") | Some("primary") => Ok(primary_home()),
        Some(id) => {
            if id.contains('\\') || id.contains('/') || id.contains("..") {
                return Err("Network 标识不合法".into());
            }
            let dir = workspaces_root().join(id);
            if dir.join("network.db").is_file() {
                Ok(dir)
            } else {
                Err(format!("找不到 Network 工作区：{id}"))
            }
        }
    }
}

fn open(home: &Path) -> Result<Connection, String> {
    let path = home.join("network.db");
    if !path.is_file() {
        return Err(format!("数据库不存在：{}", path.display()));
    }
    let db = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| format!("打开数据库失败：{e}"))?;
    db.busy_timeout(Duration::from_millis(3000))
        .map_err(|e| e.to_string())?;
    Ok(db)
}

fn has_table(db: &Connection, name: &str) -> bool {
    db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?)",
        [name],
        |row| row.get::<_, bool>(0),
    )
    .unwrap_or(false)
}

fn has_column(db: &Connection, table: &str, column: &str) -> bool {
    let sql = format!("PRAGMA table_info({table})");
    // 不用 let-else：Rows 借用 stmt，let-else 的早退分支会触发 E0597。
    let mut stmt = match db.prepare(&sql) {
        Ok(stmt) => stmt,
        Err(_) => return false,
    };
    let rows = match stmt.query_map([], |row| row.get::<_, String>(1)) {
        Ok(rows) => rows,
        Err(_) => return false,
    };
    // Flatten 借用 stmt；先落到局部变量，确保它在 stmt 之前析构。
    let found = rows.flatten().any(|name| name == column);
    found
}

struct TeamRow {
    id: String,
    name: String,
}

fn read_team(home: &Path) -> Result<Option<TeamRow>, String> {
    let path = home.join("network.db");
    if !path.is_file() {
        return Ok(None);
    }
    let db = open(home)?;
    if !has_table(&db, "kv") {
        return Ok(None);
    }
    let row = db
        .query_row(
            "SELECT COALESCE(json_extract(value,'$.id'),''),json_extract(value,'$.meta.body.name')
             FROM kv WHERE key='team'",
            [],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?)),
        )
        .optional()
        .map_err(|e| format!("读取 Network 失败：{e}"))?;
    Ok(row.map(|(id, name)| TeamRow {
        id,
        name: name.unwrap_or_else(|| "Network".to_string()),
    }))
}

fn preview(body: &str) -> String {
    let line = body.lines().find(|line| !line.trim().is_empty()).unwrap_or("");
    let mut out: String = line.chars().take(80).collect();
    if line.chars().count() > 80 {
        out.push('…');
    }
    out
}

fn without_machine(address: &str) -> &str {
    address.split_once('@').map_or(address, |(name, _)| name)
}

fn parse_files(value: Option<String>) -> Vec<Attachment> {
    let Some(raw) = value.filter(|text| !text.trim().is_empty()) else {
        return Vec::new();
    };
    let Ok(value) = serde_json::from_str::<Value>(&raw) else {
        return Vec::new();
    };
    value
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    item.get("name")
                        .and_then(Value::as_str)
                        .or_else(|| item.as_str())
                        .map(|name| Attachment {
                            name: name.to_string(),
                        })
                })
                .collect()
        })
        .unwrap_or_default()
}

fn parse_members(value: &Value) -> Vec<Member> {
    value
        .get("members")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .map(|item| Member {
                    person: item
                        .get("person")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    machine: item
                        .get("machine")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    endpoint: item
                        .get("endpoint")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    online: item.get("online").and_then(Value::as_bool).unwrap_or(false),
                    is_me: item.get("is_me").and_then(Value::as_bool).unwrap_or(false),
                    verified: item.get("verified").and_then(Value::as_bool).unwrap_or(false),
                })
                .collect()
        })
        .unwrap_or_default()
}

fn parse_directory(value: &Value) -> Vec<DirectorySession> {
    value
        .get("sessions")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .map(|item| DirectorySession {
                    address: item
                        .get("address")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    name: item
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    person: item
                        .get("person")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    agent: item
                        .get("agent")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    status: item
                        .get("status")
                        .and_then(Value::as_str)
                        .unwrap_or("offline")
                        .to_string(),
                    doing: item
                        .get("doing")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    title: item
                        .get("title")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    is_me: item.get("is_me").and_then(Value::as_bool).unwrap_or(false),
                    unread: item.get("unread").and_then(Value::as_u64).unwrap_or(0) as u32,
                    since: item.get("since").and_then(Value::as_i64),
                })
                .collect()
        })
        .unwrap_or_default()
}

fn read_locals(home: &Path) -> Result<Vec<LocalSession>, String> {
    let db = open(home)?;
    if !has_table(&db, "sessions") {
        return Ok(Vec::new());
    }
    let paused = if has_table(&db, "paused_sessions") {
        " AND key NOT IN (SELECT key FROM paused_sessions)"
    } else {
        ""
    };
    let sql = format!(
        "SELECT name,key,agent,cwd,repo,branch,doing,tier,last_seen FROM sessions
         WHERE attached=1 AND key NOT LIKE 'proc:%'{paused} ORDER BY last_seen DESC"
    );
    let mut stmt = db.prepare(&sql).map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |row| {
            Ok(LocalSession {
                name: row.get(0)?,
                key: row.get(1)?,
                agent: row.get(2)?,
                cwd: row.get(3)?,
                repo: row.get(4)?,
                branch: row.get(5)?,
                doing: row.get(6)?,
                tier: row.get(7)?,
                last_seen: row.get(8)?,
                online: false,
            })
        })
        .map_err(|e| e.to_string())?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|e| format!("读取本机会话失败：{e}"))
}

fn conversations(home: &Path, address: &str) -> Result<Vec<Conversation>, String> {
    let db = open(home)?;
    let mut map: HashMap<String, Conversation> = HashMap::new();

    let upsert = |map: &mut HashMap<String, Conversation>, raw: &str, at: i64, body: &str, unread: bool| {
        let peer = without_machine(raw).to_string();
        let item = map.entry(peer.clone()).or_insert_with(|| Conversation {
            peer,
            last_at: 0,
            preview: String::new(),
            unread: 0,
        });
        item.last_at = item.last_at.max(at);
        if !body.trim().is_empty() {
            item.preview = preview(body);
        }
        if unread {
            item.unread += 1;
        }
    };

    if has_table(&db, "messages") {
        let mut stmt = db
            .prepare(
                "SELECT sender,sent_at,body,read_at FROM messages
                 WHERE (recipient=?1 OR recipient LIKE ?1 || '@%') AND held=0 ORDER BY sent_at",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([address], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, Option<i64>>(3)?,
                ))
            })
            .map_err(|e| e.to_string())?;
        for row in rows {
            let (sender, at, body, read_at) = row.map_err(|e| e.to_string())?;
            upsert(&mut map, &sender, at, &body, read_at.is_none());
        }
    }

    if has_table(&db, "workspace_sent") {
        let mut stmt = db
            .prepare(
                "SELECT recipient,sent_at,body FROM workspace_sent
                 WHERE sender=?1 OR sender LIKE ?1 || '@%' ORDER BY sent_at",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([address], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })
            .map_err(|e| e.to_string())?;
        for row in rows {
            let (recipient, at, body) = row.map_err(|e| e.to_string())?;
            upsert(&mut map, &recipient, at, &body, false);
        }
    }

    if has_table(&db, "sent_receipts") {
        let mut stmt = db
            .prepare(
                "SELECT recipient,sent_at FROM sent_receipts
                 WHERE sender=?1 OR sender LIKE ?1 || '@%' ORDER BY sent_at",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([address], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            })
            .map_err(|e| e.to_string())?;
        for row in rows {
            let (recipient, at) = row.map_err(|e| e.to_string())?;
            upsert(&mut map, &recipient, at, "", false);
        }
    }

    let mut out: Vec<Conversation> = map.into_values().collect();
    out.sort_by(|a, b| b.last_at.cmp(&a.last_at));
    Ok(out)
}

fn chat_messages(home: &Path, address: &str, peer: &str) -> Result<Vec<ChatMessage>, String> {
    let db = open(home)?;
    let mut map: HashMap<String, ChatMessage> = HashMap::new();

    if has_table(&db, "messages") {
        let files = if has_column(&db, "messages", "files") {
            "files"
        } else {
            "NULL"
        };
        let sql = format!(
            "SELECT id,sent_at,sender,body,reply_to,{files} FROM messages
             WHERE (recipient=?1 OR recipient LIKE ?1 || '@%') AND held=0 ORDER BY sent_at"
        );
        let mut stmt = db.prepare(&sql).map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([address], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, Option<String>>(5)?,
                ))
            })
            .map_err(|e| e.to_string())?;
        for row in rows {
            let (id, at, sender, body, reply_to, files) = row.map_err(|e| e.to_string())?;
            if without_machine(&sender) != peer {
                continue;
            }
            map.insert(
                id.clone(),
                ChatMessage {
                    id,
                    at,
                    direction: "in".into(),
                    peer: peer.to_string(),
                    body,
                    reply_to,
                    stage: None,
                    attachments: parse_files(files),
                    replied: false,
                },
            );
        }
    }

    if has_table(&db, "workspace_sent") {
        let mut stmt = db
            .prepare(
                "SELECT id,sent_at,recipient,body,reply_to,files FROM workspace_sent
                 WHERE sender=?1 OR sender LIKE ?1 || '@%' ORDER BY sent_at",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([address], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, Option<String>>(5)?,
                ))
            })
            .map_err(|e| e.to_string())?;
        for row in rows {
            let (id, at, recipient, body, reply_to, files) = row.map_err(|e| e.to_string())?;
            if without_machine(&recipient) != peer {
                continue;
            }
            map.insert(
                id.clone(),
                ChatMessage {
                    id,
                    at,
                    direction: "out".into(),
                    peer: peer.to_string(),
                    body,
                    reply_to,
                    stage: None,
                    attachments: parse_files(files),
                    replied: false,
                },
            );
        }
    }

    if has_table(&db, "sent_receipts") {
        let mut stmt = db
            .prepare(
                "SELECT id,sent_at,recipient,stage FROM sent_receipts
                 WHERE sender=?1 OR sender LIKE ?1 || '@%' ORDER BY sent_at",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([address], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })
            .map_err(|e| e.to_string())?;
        for row in rows {
            let (id, at, recipient, stage) = row.map_err(|e| e.to_string())?;
            if without_machine(&recipient) != peer {
                continue;
            }
            if let Some(message) = map.get_mut(&id) {
                message.stage = Some(stage);
            } else {
                map.insert(
                    id.clone(),
                    ChatMessage {
                        id,
                        at,
                        direction: "out".into(),
                        peer: peer.to_string(),
                        body: String::new(),
                        reply_to: None,
                        stage: Some(stage),
                        attachments: Vec::new(),
                        replied: false,
                    },
                );
            }
        }
    }

    let mut list: Vec<ChatMessage> = map.into_values().collect();
    list.sort_by_key(|message| message.at);
    let start = list.len().saturating_sub(200);
    Ok(list.split_off(start))
}

pub fn list_networks() -> Result<Vec<NetworkSummary>, String> {
    let mut out = Vec::new();

    // 先让主 daemon 起来，避免只读连接撞上正在恢复的 WAL。
    let primary = primary_home();
    let _ = run_json(&primary, &["team", "--json"]);
    match read_team(&primary)? {
        Some(team) => out.push(NetworkSummary {
            id: "primary".into(),
            name: team.name,
            person: String::new(),
            machine: String::new(),
            joined: true,
            primary: true,
        }),
        None => out.push(NetworkSummary {
            id: "primary".into(),
            name: "本机 Network".into(),
            person: String::new(),
            machine: String::new(),
            joined: false,
            primary: true,
        }),
    }

    let mut workspaces = Vec::new();
    if let Ok(entries) = std::fs::read_dir(workspaces_root()) {
        for entry in entries.flatten() {
            let dir = entry.path();
            if !dir.is_dir() || !dir.join("network.db").is_file() {
                continue;
            }
            let Some(id) = dir.file_name().and_then(|name| name.to_str()) else {
                continue;
            };
            let Ok(Some(team)) = read_team(&dir) else {
                continue;
            };
            // 主 daemon 的分发需要各工作区 daemon 在线；启动时顺手拉起（和 macOS 的 KeepAlive 一致）。
            let _ = run_json(&dir, &["team", "--json"]);
            workspaces.push(NetworkSummary {
                id: id.to_string(),
                name: team.name,
                person: String::new(),
                machine: String::new(),
                joined: true,
                primary: false,
            });
        }
    }
    workspaces.sort_by(|a, b| a.name.cmp(&b.name).then(a.id.cmp(&b.id)));
    out.extend(workspaces);
    Ok(out)
}

pub fn snapshot(home: &Path, local: Option<&str>, peer: Option<&str>) -> Result<Snapshot, String> {
    // 命令会按需拉起 daemon；先跑一次，既拿到身份，也让只读连接不会撞上正在恢复的 WAL。
    let team_json = run_json(home, &["team", "--json"]);
    let Some(team) = read_team(home)? else {
        return Ok(Snapshot {
            joined: false,
            network_id: None,
            network_name: None,
            person: String::new(),
            machine: String::new(),
            members: Vec::new(),
            directory: Vec::new(),
            locals: Vec::new(),
            conversations: Vec::new(),
            messages: Vec::new(),
            selected_local: None,
            selected_peer: None,
            hint: Some("这台机器还没有加入 Network。".into()),
        });
    };

    // 后台失败时仍然展示只读历史。
    let mut hint = None;
    let (person, machine, members) = match team_json {
        Ok(value) => (
            value
                .get("person")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            value
                .get("machine")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            parse_members(&value),
        ),
        Err(error) => {
            hint = Some(format!("后台暂时不可用：{error}"));
            (String::new(), String::new(), Vec::new())
        }
    };

    let directory = match run_json(home, &["who", "--json"]) {
        Ok(value) => parse_directory(&value),
        Err(error) => {
            if hint.is_none() {
                hint = Some(format!("目录暂不可用：{error}"));
            }
            Vec::new()
        }
    };

    let mut locals = read_locals(home).unwrap_or_default();
    for session in &mut locals {
        if person.is_empty() {
            break;
        }
        let address = format!("{person}/{}", session.name);
        session.online = directory
            .iter()
            .any(|row| row.address == address && row.status != "offline");
    }

    let selected_local = local
        .filter(|name| locals.iter().any(|session| session.name == *name))
        .map(str::to_string)
        .or_else(|| locals.first().map(|session| session.name.clone()));

    let (conversation_list, mut messages, selected_peer) = match selected_local.as_deref() {
        Some(name) if !person.is_empty() => {
            let address = format!("{person}/{name}");
            let conversation_list = conversations(home, &address).unwrap_or_default();
            let selected_peer = peer
                .filter(|value| !value.is_empty())
                .map(str::to_string)
                .or_else(|| conversation_list.first().map(|item| item.peer.clone()));
            let messages = match selected_peer.as_deref() {
                Some(peer) => chat_messages(home, &address, peer).unwrap_or_default(),
                None => Vec::new(),
            };
            (conversation_list, messages, selected_peer)
        }
        _ => (Vec::new(), Vec::new(), None),
    };

    // 收到的消息如果已被某条发件引用，标成「已回复」。
    let replied: HashSet<String> = messages
        .iter()
        .filter(|message| message.direction == "out")
        .filter_map(|message| message.reply_to.clone())
        .collect();
    for message in &mut messages {
        if message.direction == "in" && replied.contains(&message.id) {
            message.replied = true;
        }
    }

    Ok(Snapshot {
        joined: true,
        network_id: Some(team.id),
        network_name: Some(team.name),
        person,
        machine,
        members,
        directory,
        locals,
        conversations: conversation_list,
        messages,
        selected_local,
        selected_peer,
        hint,
    })
}
