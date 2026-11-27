import { useEffect, useRef, useState } from "react";
import type { DirectorySession, LocalSession, Snapshot } from "../types";
import { agentLabel, splitAddress, statusLabel, withoutMachine } from "../lib/format";
import {
  CheckIcon,
  ChevronDownIcon,
  ChevronRightIcon,
  ClockIcon,
  CloseIcon,
  GearIcon,
  PersonIcon,
  SearchIcon,
  TerminalIcon,
} from "./Icons";

interface Props {
  snapshot: Snapshot | null;
  local: string | null;
  peer: string | null;
  onLocal: (name: string) => void;
  onPeer: (address: string) => void;
  onOverview: () => void;
}

function singleLine(value: string): string {
  return value
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .join(" ");
}

export default function Sidebar({ snapshot, local, peer, onLocal, onPeer, onOverview }: Props) {
  const [query, setQuery] = useState("");
  const [menuOpen, setMenuOpen] = useState(false);
  const [historyOpen, setHistoryOpen] = useState(false);
  const [collapsed, setCollapsed] = useState<Set<string>>(() => new Set());
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!menuOpen) return;
    const onPointerDown = (event: MouseEvent) => {
      if (!menuRef.current?.contains(event.target as Node)) setMenuOpen(false);
    };
    document.addEventListener("mousedown", onPointerDown);
    return () => document.removeEventListener("mousedown", onPointerDown);
  }, [menuOpen]);

  const locals = snapshot?.locals ?? [];
  const activeLocal = locals.find((session) => session.name === local) ?? null;
  const activeTitle = activeLocal ? singleLine(activeLocal.doing || activeLocal.name) : "选择本机会话";

  const localOnline = (session: LocalSession) => {
    if (!snapshot || !snapshot.person) return false;
    const address = `${snapshot.person}/${session.name}`;
    return snapshot.directory.some(
      (row) => withoutMachine(row.address) === address && row.status !== "offline",
    );
  };

  const tokens = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const matches = (values: (string | null | undefined)[]) => {
    if (tokens.length === 0) return true;
    const haystack = values.filter(Boolean).join(" ").toLowerCase();
    return tokens.every((token) => haystack.includes(token));
  };

  const remote = (snapshot?.directory ?? []).filter((session) => !session.isMe);
  const visible = remote.filter((session) =>
    matches([
      session.title,
      session.name,
      session.person,
      agentLabel(session.agent),
      session.address,
      session.doing,
    ]),
  );

  // 与 macOS 一致：先按 person 分组，再按 agent 分组。
  const grouped = new Map<string, Map<string, DirectorySession[]>>();
  for (const session of visible) {
    const agent = agentLabel(session.agent) || "其他";
    if (!grouped.has(session.person)) grouped.set(session.person, new Map());
    const agents = grouped.get(session.person)!;
    if (!agents.has(agent)) agents.set(agent, []);
    agents.get(agent)!.push(session);
  }
  const people = [...grouped.entries()]
    .map(([person, agents]) => ({
      person,
      agents: [...agents.entries()]
        .map(([agent, sessions]) => ({
          agent,
          sessions: [...sessions].sort((left, right) =>
            (left.title || left.name).localeCompare(right.title || right.name),
          ),
        }))
        .sort((left, right) => left.agent.localeCompare(right.agent)),
    }))
    .sort((left, right) => {
      if (left.person === snapshot?.person) return -1;
      if (right.person === snapshot?.person) return 1;
      return left.person.localeCompare(right.person);
    });

  const known = new Set(remote.map((session) => withoutMachine(session.address)));
  const history = (snapshot?.conversations ?? []).filter(
    (conversation) =>
      !known.has(withoutMachine(conversation.peer)) &&
      matches([conversation.peer, conversation.preview]),
  );

  const isExpanded = (key: string) => tokens.length > 0 || !collapsed.has(key);
  const toggle = (key: string) => {
    if (tokens.length > 0) return;
    setCollapsed((current) => {
      const next = new Set(current);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  };

  const selected = (address: string) =>
    peer !== null && withoutMachine(peer) === withoutMachine(address);

  // 选中的会话不能在折叠组里消失：对应分组自动展开。
  const historySelected = history.some((conversation) => selected(conversation.peer));
  const showHistory = historyOpen || historySelected;

  return (
    <aside className="sidebar">
      <div className="sidebar-head">
        <div className="sender" ref={menuRef}>
          <span
            className={`presence-dot ${activeLocal && localOnline(activeLocal) ? "online" : ""}`}
            aria-hidden="true"
          />
          <button
            type="button"
            className="sender-button"
            onClick={() => setMenuOpen((open) => !open)}
            disabled={locals.length === 0}
            title={activeLocal ? `${activeLocal.name} · ${activeLocal.cwd}` : "还没有登记的本机会话"}
          >
            <span className="sender-title">{activeTitle}</span>
            <ChevronDownIcon size={11} />
          </button>

          {menuOpen && (
            <div className="sender-popover" role="menu">
              {locals.length === 0 ? (
                <p className="menu-empty">还没有登记的本机会话</p>
              ) : (
                locals.map((session) => (
                  <button
                    key={session.key}
                    type="button"
                    role="menuitemradio"
                    aria-checked={session.name === local}
                    className={session.name === local ? "menu-row active" : "menu-row"}
                    onClick={() => {
                      onLocal(session.name);
                      setMenuOpen(false);
                    }}
                  >
                    <span
                      className={`presence-dot ${localOnline(session) ? "online" : ""}`}
                      aria-hidden="true"
                    />
                    <span className="menu-main">
                      <span className="menu-title">{singleLine(session.doing || session.name)}</span>
                      <span className="menu-sub">
                        {agentLabel(session.agent)} · {session.tier}
                        {session.branch ? ` · ${session.branch}` : ""}
                      </span>
                    </span>
                    {session.name === local && <CheckIcon size={12} />}
                  </button>
                ))
              )}
            </div>
          )}
        </div>
      </div>

      <div className="sidebar-tools">
        <label className="search-field">
          <SearchIcon size={13} />
          <input
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="搜索会话"
            spellCheck={false}
          />
          {query && (
            <button
              type="button"
              className="search-clear"
              title="清除搜索"
              onClick={() => setQuery("")}
            >
              <CloseIcon size={11} />
            </button>
          )}
        </label>
      </div>

      <div className="sidebar-scroll">
        {people.map(({ person, agents }) => {
          const personKey = `person:${person}`;
          const personExpanded =
            isExpanded(personKey) ||
            agents.some((group) => group.sessions.some((session) => selected(session.address)));
          return (
            <div className="group" key={personKey}>
              <button
                type="button"
                className="group-row person"
                onClick={() => toggle(personKey)}
                aria-expanded={personExpanded}
                title={person}
              >
                <span className={personExpanded ? "chevron expanded" : "chevron"} aria-hidden="true">
                  <ChevronRightIcon size={10} />
                </span>
                <PersonIcon size={13} />
                <span className="group-title">
                  {person}
                  {person === snapshot?.person ? " · 我" : ""}
                </span>
              </button>

              {personExpanded &&
                agents.map(({ agent, sessions }) => {
                  const agentKey = `agent:${person}:${agent}`;
                  const agentExpanded =
                    isExpanded(agentKey) || sessions.some((session) => selected(session.address));
                  return (
                    <div className="group" key={agentKey}>
                      <button
                        type="button"
                        className="group-row agent"
                        onClick={() => toggle(agentKey)}
                        aria-expanded={agentExpanded}
                        title={agent}
                      >
                        <span className={agentExpanded ? "chevron expanded" : "chevron"} aria-hidden="true">
                          <ChevronRightIcon size={10} />
                        </span>
                        <TerminalIcon size={13} />
                        <span className="group-title">{agent}</span>
                      </button>

                      {agentExpanded &&
                        sessions.map((session, index) => {
                          const title = singleLine(session.title || session.name);
                          const subtitle = title !== session.name ? session.name : "";
                          const offline = session.status === "offline";
                          return (
                            <button
                              type="button"
                              key={`${session.address}:${index}`}
                              className={selected(session.address) ? "session-row selected" : "session-row"}
                              onClick={() => onPeer(session.address)}
                              title={`${session.address}\n${statusLabel(session.status)}${
                                session.doing ? `\n${session.doing}` : ""
                              }`}
                            >
                              <span className="session-main">
                                <span className="session-title">{title}</span>
                                {subtitle && <span className="session-sub">{subtitle}</span>}
                              </span>
                              {offline && <span className="session-status">离线</span>}
                            </button>
                          );
                        })}
                    </div>
                  );
                })}
            </div>
          );
        })}

        {history.length > 0 && (
          <div className="group history-group">
            <button
              type="button"
              className="group-row history"
              onClick={() => setHistoryOpen((open) => !open)}
              aria-expanded={showHistory}
              title="历史会话"
            >
              <span className={showHistory ? "chevron expanded" : "chevron"} aria-hidden="true">
                <ChevronRightIcon size={10} />
              </span>
              <ClockIcon size={13} />
              <span className="group-title">历史会话</span>
            </button>
            {showHistory &&
              history.map((conversation) => {
                const address = splitAddress(conversation.peer);
                return (
                  <button
                    type="button"
                    key={conversation.peer}
                    className={
                      selected(conversation.peer) ? "session-row history-row selected" : "session-row history-row"
                    }
                    onClick={() => onPeer(conversation.peer)}
                    title={conversation.peer}
                  >
                    <span className="session-main">
                      <span className="session-title">{address.name}</span>
                      <span className="session-sub">{conversation.peer}</span>
                    </span>
                  </button>
                );
              })}
          </div>
        )}

        {people.length === 0 && history.length === 0 && (
          <p className="sidebar-empty">
            {query
              ? "没有匹配的会话"
              : snapshot?.joined
                ? "暂无可查看的会话"
                : "这台机器还没有加入 Network"}
          </p>
        )}
      </div>

      <footer className="sidebar-footer">
        <button
          type="button"
          className="gear-button"
          title="概览与设置"
          aria-label="概览与设置"
          onClick={onOverview}
        >
          <GearIcon size={16} />
        </button>
      </footer>
    </aside>
  );
}
