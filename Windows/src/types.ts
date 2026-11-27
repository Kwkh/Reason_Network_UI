// 与 src-tauri/src/types.rs 的 camelCase 序列化一一对应。

export interface NetworkSummary {
  id: string;
  name: string;
  person: string;
  machine: string;
  joined: boolean;
  primary: boolean;
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

export interface Conversation {
  peer: string;
  lastAt: number;
  preview: string;
  unread: number;
}

export interface Attachment {
  name: string;
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
  person: string;
  machine: string;
  members: Member[];
  directory: DirectorySession[];
  locals: LocalSession[];
  conversations: Conversation[];
  messages: ChatMessage[];
  selectedLocal: string | null;
  selectedPeer: string | null;
  hint: string | null;
}

export interface SendOutcome {
  output: string;
}

export interface NativeEntry {
  agent: string;
  id: string;
  cwd: string | null;
  project: string | null;
  title: string | null;
  updated: number;
}
