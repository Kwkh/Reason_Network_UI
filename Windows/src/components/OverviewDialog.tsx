import { useEffect, useState } from "react";
import type { LocalSession, Member, NetworkSummary, ReceiveMode, Snapshot } from "../types";
import { receiveModeLabel } from "../lib/format";
import {
  CheckIcon,
  CopyIcon,
  FolderIcon,
  GearIcon,
  LaptopIcon,
  LinkIcon,
  PlusIcon,
  RefreshIcon,
  TerminalIcon,
} from "./Icons";

interface Props {
  networks: NetworkSummary[];
  network: string | null;
  snapshot: Snapshot | null;
  busy: boolean;
  onSelectNetwork: (id: string) => void;
  onJoin: () => void;
  onCreate: () => void;
  onJoinWorkspace: () => void;
  onCreateWorkspace: () => void;
  onDeleteWorkspace: (id: string) => Promise<void>;
  onSessionParticipation: (
    session: { name: string; key: string },
    paused: boolean,
  ) => void;
  onJoinSession: (session: LocalSession, target: string) => Promise<void>;
  onInviteCode: () => void;
  onLeaveNetwork: () => void;
  onDissolveNetwork: () => void;
  onRemoveDevice: (member: Member) => void;
  onReceiveMode: (session: LocalSession, mode: ReceiveMode) => void;
  onAllParticipation: (paused: boolean) => void;
  onSetup: () => void;
  onCheckUpdate: () => void;
  onRefresh: () => void;
  onOpenFolder: () => void;
  onCopyInvite: () => void;
  onClose: () => void;
}

export default function OverviewDialog({
  networks,
  network,
  snapshot,
  busy,
  onSelectNetwork,
  onJoin,
  onCreate,
  onJoinWorkspace,
  onCreateWorkspace,
  onDeleteWorkspace,
  onSessionParticipation,
  onJoinSession,
  onInviteCode,
  onLeaveNetwork,
  onDissolveNetwork,
  onRemoveDevice,
  onReceiveMode,
  onAllParticipation,
  onSetup,
  onCheckUpdate,
  onRefresh,
  onOpenFolder,
  onCopyInvite,
  onClose,
}: Props) {
  const [confirmId, setConfirmId] = useState<string | null>(null);
  const [removing, setRemoving] = useState<string | null>(null);
  const [joiningKey, setJoiningKey] = useState<string | null>(null);
  const [adminConfirm, setAdminConfirm] = useState<"leave" | "dissolve" | null>(null);
  const [confirmRemove, setConfirmRemove] = useState<string | null>(null);
  const [modeKey, setModeKey] = useState<string | null>(null);

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        if (adminConfirm) setAdminConfirm(null);
        else if (confirmRemove) setConfirmRemove(null);
        else if (modeKey) setModeKey(null);
        else if (joiningKey) setJoiningKey(null);
        else if (confirmId) setConfirmId(null);
        else onClose();
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [onClose, adminConfirm, confirmRemove, modeKey, joiningKey, confirmId]);

  const confirmDelete = async (item: NetworkSummary) => {
    setRemoving(item.id);
    try {
      await onDeleteWorkspace(item.id);
      setConfirmId(null);
    } finally {
      setRemoving(null);
    }
  };

  const confirmJoin = async (session: LocalSession, target: string) => {
    await onJoinSession(session, target);
    setJoiningKey(null);
  };

  // 可以接入的目标：已加入、有 team id，且不是当前正在查看的 Network。
  const joinTargets = networks.filter(
    (item) => item.joined && item.teamId && item.teamId !== snapshot?.networkId,
  );

  const own = snapshot?.members.find((member) => member.isMe) ?? null;  const joined = Boolean(snapshot?.joined);
  const onlineSessions = (snapshot?.directory ?? []).filter(
    (session) => session.status !== "offline",
  ).length;
  const onlineDevices = (snapshot?.members ?? []).filter((member) => member.online).length;
  const locals = snapshot?.locals ?? [];
  const paused = snapshot?.pausedSessions ?? [];

  // 工作区列表不依赖“当前 Network 是否已加入”：主工作区没入网时也要能管理独立工作区。
  const workspaceSection =
    networks.length > 1 ? (
      <div className="overview-devices">
        <h2>工作区</h2>
        <p className="overview-help">
          独立工作区可以和当前 Network 同时存在，用上方菜单切换。
        </p>
        {networks.map((item) => {
          const current = item.id === network;
          return (
            <div className="device-row" key={item.id}>
              <FolderIcon size={16} />
              <div className="device-main">
                <span className="device-name">{item.name}</span>
                <span className="device-sub">
                  {item.primary ? "主工作区" : "独立工作区"}
                  {current ? " · 当前" : ""}
                </span>
              </div>
              {confirmId === item.id ? (
                <div className="workspace-actions">
                  <button
                    type="button"
                    className="session-action danger"
                    disabled={removing !== null}
                    onClick={() => void confirmDelete(item)}
                  >
                    {removing === item.id ? "删除中…" : "确认删除"}
                  </button>
                  <button
                    type="button"
                    className="session-action"
                    disabled={removing !== null}
                    onClick={() => setConfirmId(null)}
                  >
                    取消
                  </button>
                </div>
              ) : (
                <div className="workspace-actions">
                  {!current && (
                    <button
                      type="button"
                      className="session-action"
                      disabled={busy}
                      onClick={() => onSelectNetwork(item.id)}
                    >
                      切换
                    </button>
                  )}
                  {!item.primary && (
                    <button
                      type="button"
                      className="session-action"
                      disabled={busy || removing !== null}
                      onClick={() => setConfirmId(item.id)}
                    >
                      删除
                    </button>
                  )}
                </div>
              )}
            </div>
          );
        })}
        {confirmId && (
          <p className="overview-warn">
            删除会先结束该工作区后台，再删除本机数据库；消息记录无法恢复，主工作区不受影响。
          </p>
        )}
        <div className="overview-actions">
          <button type="button" onClick={onCreateWorkspace} disabled={busy}>
            <PlusIcon size={14} /> 新建工作区
          </button>
          <button type="button" onClick={onJoinWorkspace} disabled={busy}>
            <LinkIcon size={14} /> 加入工作区
          </button>
        </div>
      </div>
    ) : null;

  return (
    <div className="overlay" role="presentation" onMouseDown={onClose}>
      <section
        className="sheet overview"
        role="dialog"
        aria-modal="true"
        aria-label="概览"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <header className="sheet-header">
          <h1>概览</h1>
          <button type="button" className="sheet-done" onClick={onClose}>
            完成
          </button>
        </header>

        <label className="overview-network">
          <span className="sr-only">选择 Network</span>
          <select
            value={network ?? ""}
            onChange={(event) => onSelectNetwork(event.target.value)}
            disabled={networks.length === 0}
          >
            {networks.length === 0 && <option value="">未配置 Network</option>}
            {networks.map((item) => (
              <option key={item.id} value={item.id}>
                {item.name}
                {item.primary ? " · 主工作区" : ""}
              </option>
            ))}
          </select>
        </label>

        {snapshot?.person && (
          <p className="overview-person">
            <CheckIcon size={13} />
            {snapshot.person}
            {own ? (own.verified ? " · 账号已验证" : " · 账号未验证") : ""}
          </p>
        )}

        {joined ? (
          <>
            <div className="overview-actions">
              <button type="button" onClick={onCopyInvite}>
                <CopyIcon /> 复制邀请链接
              </button>
              <button type="button" onClick={onJoin}>
                <LinkIcon size={14} /> 加入 Network
              </button>
              <button type="button" onClick={onCreate}>
                <PlusIcon size={14} /> 新建 Network
              </button>
              <button type="button" onClick={onRefresh} disabled={busy}>
                <RefreshIcon size={14} /> 刷新
              </button>
              <button type="button" onClick={onOpenFolder}>
                <FolderIcon size={14} /> 打开数据目录
              </button>
              <button type="button" onClick={onSetup}>
                <GearIcon size={14} /> 环境配置
              </button>
              <button type="button" onClick={onCheckUpdate} disabled={busy}>
                <RefreshIcon size={14} /> 检查更新
              </button>
            </div>

            <div className="overview-metrics">
              <div className="metric">
                <strong>{onlineSessions}</strong>
                <span>在线会话</span>
              </div>
              <div className="metric">
                <strong>{onlineDevices}</strong>
                <span>在线设备</span>
              </div>
            </div>

            <div className="overview-devices">
              <h2>Network 管理</h2>
              <div className="overview-actions">
                <button type="button" onClick={onInviteCode} disabled={busy}>
                  <LinkIcon size={14} /> 一次性邀请码
                </button>
                <button
                  type="button"
                  onClick={() => setAdminConfirm("leave")}
                  disabled={busy}
                >
                  退出 Network…
                </button>
                {snapshot?.isFounder && (
                  <button
                    type="button"
                    className="session-action danger"
                    onClick={() => setAdminConfirm("dissolve")}
                    disabled={busy}
                  >
                    解散 Network…
                  </button>
                )}
              </div>
              {adminConfirm === "leave" && (
                <>
                  <p className="overview-warn">
                    退出后这台机器会离开当前 Network，本机记录保留；需要至少一位在线队友确认退出。
                  </p>
                  <div className="overview-actions">
                    <button
                      type="button"
                      className="session-action danger"
                      disabled={busy}
                      onClick={() => {
                        setAdminConfirm(null);
                        onLeaveNetwork();
                      }}
                    >
                      确认退出
                    </button>
                    <button
                      type="button"
                      className="session-action"
                      disabled={busy}
                      onClick={() => setAdminConfirm(null)}
                    >
                      取消
                    </button>
                  </div>
                </>
              )}
              {adminConfirm === "dissolve" && (
                <>
                  <p className="overview-warn">
                    解散后所有设备都会退出，本机和其他成员的记录不可再同步；此操作无法撤销。
                  </p>
                  <div className="overview-actions">
                    <button
                      type="button"
                      className="session-action danger"
                      disabled={busy}
                      onClick={() => {
                        setAdminConfirm(null);
                        onDissolveNetwork();
                      }}
                    >
                      确认解散
                    </button>
                    <button
                      type="button"
                      className="session-action"
                      disabled={busy}
                      onClick={() => setAdminConfirm(null)}
                    >
                      取消
                    </button>
                  </div>
                </>
              )}
            </div>

            <div className="overview-devices">
              <h2>本机会话接入</h2>
              {locals.length + paused.length === 0 ? (
                <p className="overview-empty-line">暂无本机会话</p>
              ) : (
                <>
                  {locals.length > 0 && (
                    <p className="overview-help">
                      可以把原生 agent 会话接入另一个 Network；接入后会话会同时出现在两边。
                    </p>
                  )}
                  <div className="overview-actions">
                    {locals.length > 0 && (
                      <button
                        type="button"
                        className="session-action"
                        disabled={busy}
                        onClick={() => onAllParticipation(true)}
                      >
                        全部暂停
                      </button>
                    )}
                    {paused.length > 0 && (
                      <button
                        type="button"
                        className="session-action"
                        disabled={busy}
                        onClick={() => onAllParticipation(false)}
                      >
                        全部恢复
                      </button>
                    )}
                  </div>
                  {locals.map((session) => (
                    <div className="device-row" key={session.key}>
                      <TerminalIcon size={16} />
                      <div className="device-main">
                        <span className="device-name">{session.name}</span>
                        <span className="device-sub">
                          {session.agent} · 接入中
                          {session.tier ? ` · ${receiveModeLabel(session.tier)}` : ""}
                        </span>
                      </div>
                      {modeKey === session.key ? (
                        <div className="workspace-actions">
                          {(["push", "turn", "pull"] as ReceiveMode[]).map((mode) => (
                            <button
                              key={mode}
                              type="button"
                              className="session-action"
                              disabled={busy || session.tier === mode}
                              onClick={() => {
                                setModeKey(null);
                                onReceiveMode(session, mode);
                              }}
                            >
                              {receiveModeLabel(mode)}
                            </button>
                          ))}
                          <button
                            type="button"
                            className="session-action"
                            disabled={busy}
                            onClick={() => setModeKey(null)}
                          >
                            取消
                          </button>
                        </div>
                      ) : joiningKey === session.key ? (
                        <div className="workspace-actions">
                          {joinTargets.length === 0 ? (
                            <span className="device-sub">没有其它 Network</span>
                          ) : (
                            joinTargets.map((item) => (
                              <button
                                key={item.id}
                                type="button"
                                className="session-action"
                                disabled={busy}
                                onClick={() => void confirmJoin(session, item.teamId ?? "")}
                              >
                                接入 {item.name}
                              </button>
                            ))
                          )}
                          <button
                            type="button"
                            className="session-action"
                            disabled={busy}
                            onClick={() => setJoiningKey(null)}
                          >
                            取消
                          </button>
                        </div>
                      ) : (
                        <div className="workspace-actions">
                          <button
                            type="button"
                            className="session-action"
                            disabled={busy}
                            onClick={() => {
                              setJoiningKey(null);
                              setModeKey(session.key);
                            }}
                          >
                            接收…
                          </button>
                          <button
                            type="button"
                            className="session-action"
                            disabled={busy || joinTargets.length === 0}
                            title={
                              joinTargets.length === 0
                                ? "没有其它已加入的 Network"
                                : "接入另一个 Network"
                            }
                            onClick={() => {
                              setModeKey(null);
                              setJoiningKey(session.key);
                            }}
                          >
                            接入 Network…
                          </button>
                          <button
                            type="button"
                            className="session-action"
                            disabled={busy}
                            onClick={() => onSessionParticipation(session, true)}
                          >
                            暂停
                          </button>
                        </div>
                      )}
                    </div>
                  ))}
                  {paused.map((session) => (
                    <div className="device-row paused" key={session.key}>
                      <TerminalIcon size={16} />
                      <div className="device-main">
                        <span className="device-name">{session.name}</span>
                        <span className="device-sub">
                          {session.agent || "会话"} · 已暂停
                        </span>
                      </div>
                      <button
                        type="button"
                        className="session-action"
                        disabled={busy}
                        onClick={() => onSessionParticipation(session, false)}
                      >
                        恢复
                      </button>
                    </div>
                  ))}
                </>
              )}
            </div>

            <div className="overview-devices">
              <h2>设备</h2>
              {(snapshot?.members ?? []).length === 0 ? (
                <p className="overview-empty-line">暂无设备</p>
              ) : (
                snapshot?.members.map((member) => (
                  <div className="device-row" key={`${member.machine}:${member.person}`}>
                    <LaptopIcon size={16} />
                    <div className="device-main">
                      <span className="device-name">{member.machine}</span>
                      <span className="device-sub">
                        {member.person}
                        {member.isMe ? " · 本机" : ""}
                      </span>
                    </div>
                    {confirmRemove === member.endpoint ? (
                      <div className="workspace-actions">
                        <button
                          type="button"
                          className="session-action danger"
                          disabled={busy}
                          onClick={() => {
                            setConfirmRemove(null);
                            onRemoveDevice(member);
                          }}
                        >
                          确认移除
                        </button>
                        <button
                          type="button"
                          className="session-action"
                          disabled={busy}
                          onClick={() => setConfirmRemove(null)}
                        >
                          取消
                        </button>
                      </div>
                    ) : (
                      <>
                        <span className="device-state">
                          {member.online ? "在线" : "离线"}
                        </span>
                        {snapshot?.isFounder && !member.isMe && (
                          <button
                            type="button"
                            className="session-action"
                            disabled={busy}
                            onClick={() => setConfirmRemove(member.endpoint)}
                          >
                            移除…
                          </button>
                        )}
                      </>
                    )}
                  </div>
                ))
              )}
            </div>
          </>
        ) : (
          <div className="overview-empty">
            <p>这台机器还没有加入 Network。邀请方需要保持在线。</p>
            <div className="overview-actions">
              <button type="button" className="button primary" onClick={onJoin}>
                加入 Network
              </button>
              <button type="button" className="button" onClick={onCreate}>
                新建 Network
              </button>
              <button type="button" className="button" onClick={onCheckUpdate} disabled={busy}>
                检查更新
              </button>
            </div>
          </div>
        )}

        {workspaceSection}

        {snapshot?.hint && <p className="overview-hint">{snapshot.hint}</p>}
      </section>
    </div>
  );
}
