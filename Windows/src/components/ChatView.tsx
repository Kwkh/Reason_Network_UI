import { useEffect, useRef } from "react";
import type { Attachment, ChatMessage, Snapshot } from "../types";
import {
  agentLabel,
  dayLabel,
  shortTime,
  splitAddress,
  stageLabel,
  statusLabel,
  withoutMachine,
} from "../lib/format";
import { PaperclipIcon, ReplyIcon } from "./Icons";

interface Props {
  snapshot: Snapshot | null;
  localName: string | null;
  peer: string | null;
  onReply: (message: ChatMessage) => void;
  onOpenAttachment: (attachment: Attachment) => void;
  onJoin: () => void;
  onCreate: () => void;
  onStatus: () => void;
}

function singleLine(value: string): string {
  return value
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .join(" ");
}

export default function ChatView({
  snapshot,
  localName,
  peer,
  onReply,
  onOpenAttachment,
  onJoin,
  onCreate,
  onStatus,
}: Props) {
  const listRef = useRef<HTMLDivElement>(null);
  const previousPeer = useRef<string | null>(null);

  const messages = snapshot?.messages ?? [];
  const peerInfo = snapshot?.directory.find((session) => session.address === peer) ?? null;
  const peerName = peer ? splitAddress(peer).name : "会话";

  const activeLocal = snapshot?.locals.find((session) => session.name === localName) ?? null;
  const localAddress =
    activeLocal && snapshot?.person ? `${snapshot.person}/${activeLocal.name}` : "";
  const localOnline = Boolean(
    snapshot?.directory.some(
      (session) =>
        withoutMachine(session.address) === localAddress && session.status !== "offline",
    ),
  );

  useEffect(() => {
    const node = listRef.current;
    if (!node) return;
    const changedPeer = previousPeer.current !== peer;
    const nearBottom = node.scrollHeight - node.scrollTop - node.clientHeight < 160;
    if (changedPeer || nearBottom) {
      node.scrollTop = node.scrollHeight;
    }
    previousPeer.current = peer;
  }, [peer, messages]);

  if (!snapshot) {
    return (
      <main className="chat">
        <div className="empty-state">
          <span className="spinner" />
          <p>正在连接后台</p>
        </div>
      </main>
    );
  }

  if (!snapshot.joined) {
    return (
      <main className="chat">
        <div className="empty-state">
          <p className="empty-title">连接到 Reason Network</p>
          <p>这台机器还没有加入 Network。粘贴邀请链接，或先建一个临时 Network 做联调。</p>
          <div className="empty-actions">
            <button type="button" className="button primary" onClick={onJoin}>
              加入 Network
            </button>
            <button type="button" className="button" onClick={onCreate}>
              新建 Network
            </button>
          </div>
        </div>
      </main>
    );
  }

  if (!localName) {
    return (
      <main className="chat">
        <div className="empty-state">
          <p className="empty-title">选择一个本机会话</p>
          <p>本机会话由原对话登记。先在 Codex、Claude Code 或 dsh 的原对话里接入 Network。</p>
        </div>
      </main>
    );
  }

  if (!peer) {
    return (
      <main className="chat">
        <div className="empty-state">
          <p>选择一个会话</p>
        </div>
      </main>
    );
  }

  const byId = new Map(messages.map((message) => [message.id, message]));
  let previousDay = "";
  const incomingSender = peerInfo?.person || splitAddress(peer).person || "对方";
  const peerTitle = singleLine(peerInfo?.title || peerName);
  const statusText = peerInfo ? statusLabel(peerInfo.status) : "状态未知";

  return (
    <main className="chat">
      <header className="chat-header">
        <div className="chat-title">
          <div className="chat-title-main" title={peer}>
            {peerTitle}
          </div>
          <div className="chat-title-sub">
            <span className="mono">{peer}</span>
            <span>{statusText}</span>
            {peerInfo?.doing && <span className="chat-doing">{peerInfo.doing}</span>}
          </div>
        </div>
        <button
          type="button"
          className="presence-capsule"
          onClick={onStatus}
          title="本机会话状态 · 点击查看设备"
        >
          <span className={`presence-dot ${localOnline ? "online" : ""}`} aria-hidden="true" />
          <span>{localOnline ? "在线" : "离线"}</span>
        </button>
      </header>

      {snapshot.hint && (
        <div className="chat-error" role="status">
          <span>{snapshot.hint}</span>
        </div>
      )}

      <div className="messages" ref={listRef}>
        {messages.length === 0 && (
          <div className="messages-empty">
            <p>还没有消息</p>
          </div>
        )}
        {messages.map((message) => {
          const day = dayLabel(message.at);
          const showDay = day !== previousDay;
          previousDay = day;
          const quoted = message.replyTo ? byId.get(message.replyTo) : undefined;
          const stage = stageLabel(message.stage);
          const incoming = message.direction === "in";
          return (
            <div key={`${message.direction}-${message.id}`}>
              {showDay && <div className="day-divider">{day}</div>}
              <article className={`message-row ${incoming ? "in" : "out"}`}>
                <div className="message-head">
                  {incoming ? incomingSender : "我"} · {shortTime(message.at)}
                  {peerInfo && incoming && <span className="message-agent"> · {agentLabel(peerInfo.agent)}</span>}
                </div>
                <div className="message-bubble">
                  {quoted && (
                    <blockquote className="quoted" title={quoted.body}>
                      <span>{quoted.direction === "in" ? "对方" : "我"}：</span>
                      {quoted.body || "（正文不可用）"}
                    </blockquote>
                  )}
                  <p className="message-body">
                    {message.body || "（正文不可用，仅收到投递回执）"}
                  </p>
                  {message.attachments.length > 0 && (
                    <ul className="attachments">
                      {message.attachments.map((file, index) => {
                        const openable = message.direction === "in" && file.directory !== null;
                        return (
                          <li key={`${file.name}-${index}`}>
                            {openable ? (
                              <button
                                type="button"
                                className="attachment-link"
                                title={`打开 ${file.name}`}
                                onClick={() => onOpenAttachment(file)}
                              >
                                <PaperclipIcon size={11} />
                                <span>{file.name}</span>
                              </button>
                            ) : (
                              <span className="attachment-name" title={file.name}>
                                <PaperclipIcon size={11} />
                                <span>{file.name}</span>
                              </span>
                            )}
                          </li>
                        );
                      })}
                    </ul>
                  )}
                </div>
                <div className="message-foot">
                  {!incoming && stage && <span>{stage}</span>}
                  {incoming && message.replied && <span>已回复</span>}
                  {incoming && !message.replied && (
                    <button
                      type="button"
                      className="message-action"
                      onClick={() => onReply(message)}
                      title="引用这条消息回复"
                    >
                      <ReplyIcon size={12} /> 回复
                    </button>
                  )}
                </div>
              </article>
            </div>
          );
        })}
      </div>
    </main>
  );
}
