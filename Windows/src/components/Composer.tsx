import { useEffect, useRef } from "react";
import type { AttachmentDraft, ChatMessage } from "../types";
import { splitAddress } from "../lib/format";
import { ArrowUpIcon, BellIcon, CloseIcon, PaperclipIcon, PlusIcon } from "./Icons";

interface Props {
  value: string;
  replyTo: ChatMessage | null;
  files: AttachmentDraft[];
  notify: boolean;
  disabled: boolean;
  busy: boolean;
  onChange: (value: string) => void;
  onSend: () => void;
  onCancelReply: () => void;
  onPickFiles: () => void;
  onRemoveFile: (path: string) => void;
  onToggleNotify: () => void;
}

function sizeLabel(size: number): string {
  if (size < 1024) return `${size} B`;
  return `${(size / 1024).toFixed(1)} KiB`;
}

export default function Composer({
  value,
  replyTo,
  files,
  notify,
  disabled,
  busy,
  onChange,
  onSend,
  onCancelReply,
  onPickFiles,
  onRemoveFile,
  onToggleNotify,
}: Props) {
  const inputRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    const node = inputRef.current;
    if (!node) return;
    node.style.height = "auto";
    node.style.height = `${Math.min(node.scrollHeight, 156)}px`;
  }, [value]);

  useEffect(() => {
    if (replyTo) inputRef.current?.focus();
  }, [replyTo]);

  const canSend = !disabled && !busy && (value.trim().length > 0 || files.length > 0);

  return (
    <footer className="composer">
      <div className={replyTo ? "composer-box has-reply" : "composer-box"}>
        {files.length > 0 && (
          <div className="attachment-chips" aria-label="待发送附件">
            {files.map((file) => (
              <span key={file.path} className="attachment-chip" title={`${file.path} · ${sizeLabel(file.size)}`}>
                <PaperclipIcon size={11} />
                <span className="attachment-chip-name">{file.name}</span>
                <button
                  type="button"
                  className="attachment-chip-remove"
                  title={`移除 ${file.name}`}
                  aria-label={`移除 ${file.name}`}
                  onClick={() => onRemoveFile(file.path)}
                >
                  <CloseIcon size={10} />
                </button>
              </span>
            ))}
          </div>
        )}
        {replyTo && (
          <div className="reply-chip">
            <span>
              回复 <strong>{splitAddress(replyTo.peer).name || "这条消息"}</strong>：
              {replyTo.body.slice(0, 80) || "（附件消息）"}
            </span>
            <button type="button" className="icon-button" title="取消回复" onClick={onCancelReply}>
              <CloseIcon size={12} />
            </button>
          </div>
        )}
        <textarea
          ref={inputRef}
          value={value}
          placeholder={disabled ? "先选择会话" : "输入消息"}
          disabled={disabled}
          rows={1}
          onChange={(event) => onChange(event.target.value)}
          onKeyDown={(event) => {
            if (event.key !== "Enter" || event.shiftKey) return;
            // 中文输入法组词时不要误发。
            if (event.nativeEvent.isComposing || event.keyCode === 229) return;
            event.preventDefault();
            if (canSend) onSend();
          }}
        />
        <div className="composer-actions">
          <button
            type="button"
            className="composer-plus"
            title="添加文本附件"
            aria-label="添加文本附件"
            disabled={disabled || busy}
            onClick={onPickFiles}
          >
            <PlusIcon size={14} />
          </button>
          <button
            type="button"
            className={notify ? "composer-plus active" : "composer-plus"}
            title={notify ? "发送时会在对方电脑上弹窗提醒" : "在对方电脑上弹窗提醒"}
            aria-label="在对方电脑上弹窗提醒"
            aria-pressed={notify}
            disabled={disabled || busy}
            onClick={onToggleNotify}
          >
            <BellIcon size={14} />
          </button>
          <span className="composer-hint">Enter 发送 · Shift + Enter 换行</span>
          <button
            type="button"
            className={canSend ? "composer-send enabled" : "composer-send"}
            onClick={onSend}
            disabled={!canSend}
            title="发送消息"
            aria-label={busy ? "发送中" : "发送消息"}
          >
            {busy ? <span className="spinner small" /> : <ArrowUpIcon size={15} />}
          </button>
        </div>
      </div>
    </footer>
  );
}
