import { useEffect, useRef } from "react";
import type { ChatMessage, Snapshot } from "../types";
import {
  agentLabel,
  dayLabel,
  shortTime,
  splitAddress,
  stageLabel,
  statusLabel,
} from "../lib/format";
import { RefreshIcon, ReplyIcon } from "./Icons";

interface Props {
  snapshot: Snapshot | null;
  localName: string | null;
  peer: string | null;
  onReply: (message: ChatMessage) => void;
  onRefresh: () => void;
  onJoin: () => void;
  onCreate: () => void;
}

export default function ChatView({
  snapshot,
  localName,
  peer,
  onReply,
  onRefresh,
  onJoin,
  onCreate,
}: Props) {
  const listRef = useRef<HTMLDivElement>(null);
  const previousPeer = useRef<string | null>(null);

  const messages = snapshot?.messages ?? [];
  const peerInfo = snapshot?.directory.find((session) => session.address === peer) ?? null;
  const peerName = peer ? splitAddress(peer).name : "对话";

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
        <div className="main-empty">
          <div className="empty-card">
            <span className="spinner" />
            <h1>正在连接后台</h1>
            <p>首次读取会自动启动本机的 Reason Network 服务。</p>
          </div>
        </div>
      </main>
    );
  }

  if (!snapshot.joined) {
    return (
      <main className="chat">
        <div className="main-empty">
          <div className="empty-card">
            <span className="empty-mark" aria-hidden="true">
              RN
            </span>
            <h1>连接到 Reason Network</h1>
            <p>
              这台机器还没有加入 Network。粘贴队友的邀请链接，或先建一个临时 Network 做联调。
            </p>
            <div className="button-row">
              <button type="button" className="primary" onClick={onJoin}>
                加入 Network
              </button>
              <button type="button" onClick={onCreate}>
                新建 Network
              </button>
            </div>
          </div>
        </div>
      </main>
    );
  }

  if (!localName) {
    return (
      <main className="chat">
        <div className="main-empty">
          <div className="empty-card">
            <h1>选择一个本机会话</h1>
            <p>
              本机会话由 Codex、Claude Code、Gemini CLI 或 dsh 的原对话登记。先在原对话里接入
              Network，再回到这里刷新。
            </p>
            <button type="button" className="primary" onClick={onRefresh}>
              刷新状态
            </button>
          </div>
        </div>
      </main>
    );
  }

  if (!peer) {
    return (
      <main className="chat">
        <div className="main-empty">
          <div className="empty-card">
            <h1>选择对话对象</h1>
            <p>从左侧的「对话」或「目录」里选一个队友会话，开始收发消息。</p>
          </div>
        </div>
      </main>
    );
  }

  const byId = new Map(messages.map((message) => [message.id, message]));
  let previousDay = "";

  return (
    <main className="chat">
      <header className="chat-header">
        <div className="chat-title">
          <span
            className={peerInfo && peerInfo.status !== "offline" ? "dot online" : "dot"}
            title={peerInfo ? statusLabel(peerInfo.status) : "状态未知"}
          />
          <div>
            <h2>
              {peerName}
              <span className="muted"> · {splitAddress(peer).person}</span>
            </h2>
            <p className="chat-sub">
              {peerInfo
                ? `${agentLabel(peerInfo.agent)} · ${statusLabel(peerInfo.status)}${
                    peerInfo.doing ? ` · ${peerInfo.doing}` : ""
                  }`
                : peer}
            </p>
          </div>
        </div>
        <div className="chat-actions">
          <button type="button" className="icon-button" title="刷新" onClick={onRefresh}>
            <RefreshIcon />
          </button>
        </div>
      </header>

      <div className="messages" ref={listRef}>
        {messages.length === 0 && (
          <div className="messages-empty">
            <p>还没有消息。</p>
            <p className="muted">在下方输入第一条消息；发送后会由本机后台投递给对方原会话。</p>
          </div>
        )}
        {messages.map((message) => {
          const day = dayLabel(message.at);
          const showDay = day !== previousDay;
          previousDay = day;
          const quoted = message.replyTo ? byId.get(message.replyTo) : undefined;
          const stage = stageLabel(message.stage);
          return (
            <div key={`${message.direction}-${message.id}`}>
              {showDay && <div className="day-divider">{day}</div>}
              <article className={`message ${message.direction}`}>
                <div className="bubble">
                  {quoted && (
                    <blockquote className="quoted" title={quoted.body}>
                      <span>{quoted.direction === "in" ? "对方" : "我"}：</span>
                      {quoted.body || "（正文不可用）"}
                    </blockquote>
                  )}
                  <p className="body">{message.body || "（正文不可用，仅收到投递回执）"}</p>
                  {message.attachments.length > 0 && (
                    <ul className="attachments">
                      {message.attachments.map((file) => (
                        <li key={file.name} title={file.name}>
                          📎 {file.name}
                        </li>
                      ))}
                    </ul>
                  )}
                </div>
                <div className="message-meta">
                  <time>{shortTime(message.at)}</time>
                  {message.direction === "out" && stage && <span className="stage">{stage}</span>}
                  {message.direction === "in" && message.replied && (
                    <span className="stage replied">已回复</span>
                  )}
                  {message.direction === "in" && !message.replied && (
                    <button
                      type="button"
                      className="link-button"
                      onClick={() => onReply(message)}
                      title="引用这条消息回复"
                    >
                      <ReplyIcon size={13} /> 回复
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
