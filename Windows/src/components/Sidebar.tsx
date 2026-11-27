import type { NetworkSummary, Snapshot } from "../types";
import { agentLabel, relativeTime, splitAddress, statusLabel } from "../lib/format";
import { FolderIcon, LinkIcon, PlusIcon, RefreshIcon, UsersIcon } from "./Icons";

interface Props {
  networks: NetworkSummary[];
  network: string | null;
  snapshot: Snapshot | null;
  local: string | null;
  peer: string | null;
  busy: boolean;
  onNetwork: (id: string) => void;
  onLocal: (name: string) => void;
  onPeer: (address: string) => void;
  onJoin: () => void;
  onCreate: () => void;
  onRefresh: () => void;
  onOpenFolder: () => void;
}

export default function Sidebar({
  networks,
  network,
  snapshot,
  local,
  peer,
  busy,
  onNetwork,
  onLocal,
  onPeer,
  onJoin,
  onCreate,
  onRefresh,
  onOpenFolder,
}: Props) {
  const activeLocal =
    snapshot?.locals.find((session) => session.name === (local ?? snapshot.selectedLocal)) ?? null;
  const selectedPeer = peer ?? snapshot?.selectedPeer ?? null;
  const conversations = snapshot?.conversations ?? [];
  const remote = (snapshot?.directory ?? [])
    .filter((session) => !session.isMe)
    .sort((left, right) => {
      const leftOffline = left.status === "offline" ? 1 : 0;
      const rightOffline = right.status === "offline" ? 1 : 0;
      return (
        leftOffline - rightOffline ||
        left.person.localeCompare(right.person) ||
        left.name.localeCompare(right.name)
      );
    });
  const onlineMembers = (snapshot?.members ?? []).filter((member) => member.online).length;
  const current = networks.find((item) => item.id === network) ?? null;

  return (
    <aside className="sidebar">
      <header className="brand">
        <span className="brand-mark" aria-hidden="true">
          RN
        </span>
        <span className="brand-text">
          <strong>Reason Network</strong>
          <small>Windows 预览</small>
        </span>
      </header>

      <div className="network-switcher">
        <label className="sr-only" htmlFor="network-select">
          切换 Network
        </label>
        <select
          id="network-select"
          value={network ?? ""}
          onChange={(event) => onNetwork(event.target.value)}
          disabled={networks.length === 0}
        >
          {networks.length === 0 && <option value="">未配置</option>}
          {networks.map((item) => (
            <option key={item.id} value={item.id}>
              {item.name}
              {item.primary ? " · 主工作区" : ""}
            </option>
          ))}
        </select>
        <button type="button" className="icon-button" title="加入 Network" onClick={onJoin}>
          <LinkIcon />
        </button>
        <button type="button" className="icon-button" title="新建 Network" onClick={onCreate}>
          <PlusIcon />
        </button>
      </div>

      <div className="sidebar-scroll">
        <section className="panel">
          <div className="panel-title">
            <span>本机会话</span>
            <span className="count">{snapshot?.locals.length ?? 0}</span>
          </div>
          {(snapshot?.locals.length ?? 0) === 0 ? (
            <p className="empty">还没有登记的会话。先在 Codex 原对话里接入 Network，再回到这里刷新。</p>
          ) : (
            <ul className="rows">
              {snapshot?.locals.map((session) => (
                <li key={session.key}>
                  <button
                    type="button"
                    className={session.name === activeLocal?.name ? "row active" : "row"}
                    onClick={() => onLocal(session.name)}
                    title={session.cwd}
                  >
                    <span className={session.online ? "dot online" : "dot"} />
                    <span className="row-main">
                      <span className="row-name">{session.name}</span>
                      <span className="row-sub">
                        {agentLabel(session.agent)} · {session.doing ?? session.cwd}
                      </span>
                    </span>
                    <span className="badge">{session.tier}</span>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </section>

        <section className="panel">
          <div className="panel-title">
            <span>对话</span>
            <span className="count">{conversations.length}</span>
          </div>
          {conversations.length === 0 ? (
            <p className="empty">{activeLocal ? "这个会话还没有消息。" : "先选择一个本机会话。"}</p>
          ) : (
            <ul className="rows">
              {conversations.map((conversation) => {
                const address = splitAddress(conversation.peer);
                return (
                  <li key={conversation.peer}>
                    <button
                      type="button"
                      className={conversation.peer === selectedPeer ? "row active" : "row"}
                      onClick={() => onPeer(conversation.peer)}
                    >
                      <span className="peer-avatar" aria-hidden="true">
                        {address.name.slice(0, 1).toUpperCase()}
                      </span>
                      <span className="row-main">
                        <span className="row-name">
                          {address.name}
                          {address.person && <span className="muted"> · {address.person}</span>}
                        </span>
                        <span className="row-sub">{conversation.preview || "（没有正文）"}</span>
                      </span>
                      <span className="row-meta">
                        <span className="muted">{relativeTime(conversation.lastAt)}</span>
                        {conversation.unread > 0 && <span className="unread">{conversation.unread}</span>}
                      </span>
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
        </section>

        <section className="panel">
          <div className="panel-title">
            <span>目录</span>
            <span className="count">{remote.length}</span>
          </div>
          {remote.length === 0 ? (
            <p className="empty">队友和他们的会话会出现在这里。</p>
          ) : (
            <ul className="rows compact">
              {remote.map((session) => (
                <li key={session.address}>
                  <button
                    type="button"
                    className={session.address === selectedPeer ? "row active" : "row"}
                    onClick={() => onPeer(session.address)}
                    title={`${session.address} · ${statusLabel(session.status)}`}
                  >
                    <span
                      className={session.status === "offline" ? "dot" : "dot online"}
                      title={statusLabel(session.status)}
                    />
                    <span className="row-main">
                      <span className="row-name">{session.name}</span>
                      <span className="row-sub">
                        {session.person} · {agentLabel(session.agent)} · {statusLabel(session.status)}
                      </span>
                    </span>
                    {session.unread > 0 && <span className="unread">{session.unread}</span>}
                  </button>
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>

      <footer className="sidebar-footer">
        <div className="footer-line">
          <span className="identity">
            <span className={snapshot?.person ? "dot online" : "dot"} />
            {snapshot?.person || "未加入"}
            {snapshot?.machine && <span className="muted">@ {snapshot.machine}</span>}
          </span>
          <span className="footer-actions">
            <button
              type="button"
              className="icon-button"
              title="刷新"
              onClick={onRefresh}
              disabled={busy}
            >
              <RefreshIcon />
            </button>
            <button type="button" className="icon-button" title="打开数据目录" onClick={onOpenFolder}>
              <FolderIcon />
            </button>
          </span>
        </div>
        <div className="footer-line muted small">
          <span>
            <UsersIcon size={14} /> {onlineMembers} / {snapshot?.members.length ?? 0} 台在线
          </span>
          {current && !current.joined && <span>未加入</span>}
        </div>
        {snapshot?.hint && (
          <p className="hint" title={snapshot.hint}>
            {snapshot.hint}
          </p>
        )}
      </footer>
    </aside>
  );
}
