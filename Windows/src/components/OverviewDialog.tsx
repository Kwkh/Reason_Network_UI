import { useEffect } from "react";
import type { NetworkSummary, Snapshot } from "../types";
import {
  CheckIcon,
  CopyIcon,
  FolderIcon,
  LaptopIcon,
  LinkIcon,
  PlusIcon,
  RefreshIcon,
} from "./Icons";

interface Props {
  networks: NetworkSummary[];
  network: string | null;
  snapshot: Snapshot | null;
  busy: boolean;
  onSelectNetwork: (id: string) => void;
  onJoin: () => void;
  onCreate: () => void;
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
  onRefresh,
  onOpenFolder,
  onCopyInvite,
  onClose,
}: Props) {
  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [onClose]);

  const own = snapshot?.members.find((member) => member.isMe) ?? null;
  const joined = Boolean(snapshot?.joined);
  const onlineSessions = (snapshot?.directory ?? []).filter(
    (session) => session.status !== "offline",
  ).length;
  const onlineDevices = (snapshot?.members ?? []).filter((member) => member.online).length;

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
                    <span className="device-state">{member.online ? "在线" : "离线"}</span>
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
            </div>
          </div>
        )}

        {snapshot?.hint && <p className="overview-hint">{snapshot.hint}</p>}
      </section>
    </div>
  );
}
