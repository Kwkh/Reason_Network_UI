use serde::{Deserialize, Serialize};

/// 一个可切换的 Network：主工作区或 `~/.reason/workspaces/<id>`。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NetworkSummary {
    pub id: String,
    pub name: String,
    pub person: String,
    pub machine: String,
    pub joined: bool,
    pub primary: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Member {
    pub person: String,
    pub machine: String,
    pub endpoint: String,
    pub online: bool,
    pub is_me: bool,
    pub verified: bool,
}

/// 引擎数据库 `sessions` 表里登记的本地会话。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalSession {
    pub name: String,
    pub key: String,
    pub agent: String,
    pub cwd: String,
    pub repo: Option<String>,
    pub branch: Option<String>,
    pub doing: Option<String>,
    pub tier: String,
    pub last_seen: i64,
    pub online: bool,
}

/// `who --json` 返回的本机与队友会话目录。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DirectorySession {
    pub address: String,
    pub name: String,
    pub person: String,
    pub agent: String,
    pub status: String,
    pub doing: Option<String>,
    pub title: Option<String>,
    pub is_me: bool,
    pub unread: u32,
    pub since: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    pub peer: String,
    pub last_at: i64,
    pub preview: String,
    pub unread: u32,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Attachment {
    pub name: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatMessage {
    pub id: String,
    pub at: i64,
    /// `in` 或 `out`
    pub direction: String,
    pub peer: String,
    pub body: String,
    pub reply_to: Option<String>,
    pub stage: Option<String>,
    pub attachments: Vec<Attachment>,
    /// 这条收到的消息是否已被本机回复。
    pub replied: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub joined: bool,
    pub network_id: Option<String>,
    pub network_name: Option<String>,
    pub person: String,
    pub machine: String,
    pub members: Vec<Member>,
    pub directory: Vec<DirectorySession>,
    pub locals: Vec<LocalSession>,
    pub conversations: Vec<Conversation>,
    pub messages: Vec<ChatMessage>,
    pub selected_local: Option<String>,
    pub selected_peer: Option<String>,
    /// 后台或目录读取失败时的提示，界面只展示不阻塞。
    pub hint: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SendOutcome {
    pub output: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeEntry {
    pub agent: String,
    pub id: String,
    pub cwd: Option<String>,
    pub project: Option<String>,
    pub title: Option<String>,
    pub updated: f64,
}
