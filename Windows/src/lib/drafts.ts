/**
 * 每会话草稿：正文、待发附件路径、提醒开关和回复目标都按
 * `network + 本机会话 + 对方会话` 分开保存。
 *
 * 使用 localStorage（每个 WebView 独立）；读写都可能因隐私模式或配额失败，
 * 失败时退化为不持久化，不影响发送。
 */

export interface StoredDraft {
  text: string;
  files: string[];
  notify: boolean;
  replyTo: string | null;
}

const PREFIX = "rn.draft.v1.";

export function draftKey(
  network: string | null,
  local: string | null,
  peer: string | null,
): string | null {
  if (!local || !peer) return null;
  return `${PREFIX}${network ?? "primary"}:${local}:${peer}`;
}

function storage(): Storage | null {
  try {
    return window.localStorage;
  } catch {
    return null;
  }
}

export function readDraft(key: string | null): StoredDraft | null {
  if (!key) return null;
  try {
    const raw = storage()?.getItem(key);
    if (!raw) return null;
    const value = JSON.parse(raw) as Partial<StoredDraft>;
    if (typeof value.text !== "string") return null;
    return {
      text: value.text,
      files: Array.isArray(value.files)
        ? value.files.filter((path): path is string => typeof path === "string")
        : [],
      notify: value.notify === true,
      replyTo: typeof value.replyTo === "string" ? value.replyTo : null,
    };
  } catch {
    return null;
  }
}

export function writeDraft(key: string | null, draft: StoredDraft): void {
  if (!key) return;
  try {
    storage()?.setItem(key, JSON.stringify(draft));
  } catch {
    // 配额或权限问题：放弃持久化。
  }
}

export function removeDraft(key: string | null): void {
  if (!key) return;
  try {
    storage()?.removeItem(key);
  } catch {
    // 忽略。
  }
}

/** 空草稿不落盘，避免 localStorage 里堆满空记录。 */
export function persistDraft(key: string | null, draft: StoredDraft): void {
  if (!key) return;
  if (!draft.text && draft.files.length === 0 && !draft.notify && !draft.replyTo) {
    removeDraft(key);
  } else {
    writeDraft(key, draft);
  }
}
