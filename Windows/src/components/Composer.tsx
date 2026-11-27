import { useEffect, useRef } from "react";
import type { ChatMessage } from "../types";
import { splitAddress } from "../lib/format";
import { CloseIcon, SendIcon } from "./Icons";

interface Props {
  value: string;
  replyTo: ChatMessage | null;
  disabled: boolean;
  busy: boolean;
  onChange: (value: string) => void;
  onSend: () => void;
  onCancelReply: () => void;
}

export default function Composer({
  value,
  replyTo,
  disabled,
  busy,
  onChange,
  onSend,
  onCancelReply,
}: Props) {
  const inputRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    const node = inputRef.current;
    if (!node) return;
    node.style.height = "auto";
    node.style.height = `${Math.min(node.scrollHeight, 168)}px`;
  }, [value]);

  useEffect(() => {
    if (replyTo) inputRef.current?.focus();
  }, [replyTo]);

  const canSend = !disabled && !busy && value.trim().length > 0;

  return (
    <footer className="composer">
      {replyTo && (
        <div className="reply-chip">
          <span>
            回复 <strong>{splitAddress(replyTo.peer).name || "这条消息"}</strong>：
            {replyTo.body.slice(0, 80) || "（附件消息）"}
          </span>
          <button type="button" className="icon-button" title="取消回复" onClick={onCancelReply}>
            <CloseIcon size={14} />
          </button>
        </div>
      )}
      <div className="composer-box">
        <textarea
          ref={inputRef}
          value={value}
          placeholder={disabled ? "先选择会话" : "输入消息，Enter 发送，Shift + Enter 换行"}
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
        <button
          type="button"
          className="send-button"
          onClick={onSend}
          disabled={!canSend}
          title="发送"
        >
          {busy ? <span className="spinner small" /> : <SendIcon />}
        </button>
      </div>
      <div className="composer-hint">
        <span>Enter 发送 · Shift + Enter 换行</span>
        <span className="muted">{value.length > 0 ? `${value.length} 字` : ""}</span>
      </div>
    </footer>
  );
}
