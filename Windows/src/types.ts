// 与 src-tauri/src/types.rs 的 camelCase 序列化一一对应。

export interface NetworkSummary {
  id: string;
  name: string;
  /** 团队 id：主工作区和独立工作区都有，用于把本机会话接入指定 Network。 */
  teamId: string | null;
  person: string;
  machine: string;
  joined: boolean;
  primary: boolean;
}

/** 把本机会话接入 Network 后返回的地址。 */
export interface JoinResult {
  networkId: string;
  networkName: string;
  address: string;
  online: boolean;
}

export interface Member {
  person: string;
  machine: string;
  endpoint: string;
  online: boolean;
  isMe: boolean;
  verified: boolean;
}

export interface LocalSession {
  name: string;
  key: string;
  agent: string;
  cwd: string;
  repo: string | null;
  branch: string | null;
  doing: string | null;
  tier: string;
  lastSeen: number;
  online: boolean;
}

/** 已暂停接入的本机会话。 */
export interface PausedSession {
  name: string;
  key: string;
  agent: string;
}

export interface DirectorySession {
  address: string;
  name: string;
  person: string;
  agent: string;
  status: string;
  doing: string | null;
  title: string | null;
  isMe: boolean;
  unread: number;
  since: number | null;
}

/** 某个队友会话最近一条来信，用于桌面通知。 */
export interface IncomingNotice {
  peer: string;
  local: string;
  messageId: string;
  at: number;
  sender: string;
  preview: string;
}

export interface Conversation {
  peer: string;
  lastAt: number;
  preview: string;
  unread: number;
}

export interface Attachment {
  name: string;
  /** 来信附件的收件箱子目录；发件记录没有。 */
  directory: string | null;
}

/** 已通过验证、等待发送的本地附件。 */
export interface AttachmentDraft {
  path: string;
  name: string;
  size: number;
}

export interface ChatMessage {
  id: string;
  at: number;
  direction: "in" | "out";
  peer: string;
  body: string;
  replyTo: string | null;
  stage: string | null;
  attachments: Attachment[];
  replied: boolean;
}

export interface Snapshot {
  joined: boolean;
  networkId: string | null;
  networkName: string | null;
  /** 当前机器是否是 Network 创建者（决定能否解散、移除设备）。 */
  isFounder: boolean;
  person: string;
  machine: string;
  members: Member[];
  directory: DirectorySession[];
  locals: LocalSession[];
  pausedSessions: PausedSession[];
  conversations: Conversation[];
  messages: ChatMessage[];
  incoming: IncomingNotice[];
  selectedLocal: string | null;
  selectedPeer: string | null;
  hint: string | null;
}

export interface SendOutcome {
  output: string;
}

export interface BackendInfo {
  path: string;
  version: string;
  source: string;
}

export interface NativeEntry {
  agent: string;
  id: string;
  cwd: string | null;
  project: string | null;
  title: string | null;
  updated: number;
}

/** 批量暂停/恢复的结果。 */
export interface ParticipationBatch {
  changed: number;
  failures: { key: string; error: string }[];
}

/** 本机会话的接收模式。 */
export type ReceiveMode = "push" | "turn" | "pull";
