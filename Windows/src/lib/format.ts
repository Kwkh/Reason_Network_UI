const AGENT_LABELS: Record<string, string> = {
  codex: "Codex",
  "claude-code": "Claude Code",
  gemini: "Gemini CLI",
  dsh: "dsh",
  cursor: "Cursor",
  opencode: "OpenCode",
  pi: "Pi",
  hermes: "Hermes",
};

const STATUS_LABELS: Record<string, string> = {
  busy: "忙碌",
  idle: "空闲",
  live: "在线",
  offline: "离线",
};

const STAGE_LABELS: Record<string, string> = {
  accepted: "已接收",
  queued: "已排队",
  held: "待批准",
  pushed: "已推送",
  delivered: "已送达",
  rejected: "被拒绝",
  unknown: "状态未知",
};

export function withoutMachine(address: string): string {
  const at = address.indexOf("@");
  return at === -1 ? address : address.slice(0, at);
}

export function splitAddress(address: string): { person: string; name: string } {
  const clean = withoutMachine(address);
  const slash = clean.lastIndexOf("/");
  if (slash === -1) {
    return { person: "", name: clean };
  }
  return { person: clean.slice(0, slash), name: clean.slice(slash + 1) };
}

export function agentLabel(agent: string): string {
  return AGENT_LABELS[agent] ?? agent;
}

export function statusLabel(status: string): string {
  return STATUS_LABELS[status] ?? status;
}

export function stageLabel(stage: string | null): string | null {
  if (!stage) return null;
  return STAGE_LABELS[stage] ?? stage;
}

export function shortTime(ms: number): string {
  if (!ms) return "";
  return new Date(ms).toLocaleTimeString("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

export function relativeTime(ms: number): string {
  if (!ms) return "";
  const delta = Date.now() - ms;
  if (delta < 60_000) return "刚刚";
  if (delta < 3_600_000) return `${Math.floor(delta / 60_000)} 分钟前`;
  if (delta < 86_400_000) return `${Math.floor(delta / 3_600_000)} 小时前`;
  if (delta < 172_800_000) return "昨天";
  return new Date(ms).toLocaleDateString("zh-CN", { month: "numeric", day: "numeric" });
}

export function dayLabel(ms: number): string {
  const date = new Date(ms);
  const today = new Date();
  const yesterday = new Date();
  yesterday.setDate(today.getDate() - 1);
  const same = (a: Date, b: Date) =>
    a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate();
  if (same(date, today)) return "今天";
  if (same(date, yesterday)) return "昨天";
  return date.toLocaleDateString("zh-CN", {
    year: "numeric",
    month: "long",
    day: "numeric",
  });
}
