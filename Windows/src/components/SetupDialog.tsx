import { useCallback, useEffect, useState } from "react";
import {
  appIntegrations,
  backendInfo,
  nativeCatalog,
  setupConfigure,
  setupPreview,
} from "../api";
import type { BackendInfo, Snapshot } from "../types";
import {
  CheckIcon,
  RefreshIcon,
  TerminalIcon,
} from "./Icons";

interface Props {
  snapshot: Snapshot | null;
  onClose: () => void;
}

const AGENT_LABELS: Record<string, string> = {
  codex: "Codex",
  "claude-code": "Claude Code",
  gemini: "Gemini CLI",
  dsh: "dsh",
  copilot: "Copilot CLI",
};

function errorText(cause: unknown): string {
  if (typeof cause === "string") return cause;
  if (cause instanceof Error) return cause.message;
  try {
    return JSON.stringify(cause);
  } catch {
    return String(cause);
  }
}

export default function SetupDialog({ snapshot, onClose }: Props) {
  const [info, setInfo] = useState<BackendInfo | null>(null);
  const [agents, setAgents] = useState<string[]>([]);
  const [preview, setPreview] = useState("");
  const [catalog, setCatalog] = useState<number | null>(null);
  const [output, setOutput] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [confirming, setConfirming] = useState(false);

  const refresh = useCallback(async () => {
    setBusy(true);
    setError(null);
    try {
      const [nextInfo, nextAgents, nextPreview, nextCatalog] = await Promise.all([
        backendInfo(),
        appIntegrations().catch(() => []),
        setupPreview().catch(() => ""),
        nativeCatalog().catch(() => []),
      ]);
      setInfo(nextInfo);
      setAgents(nextAgents);
      setPreview(nextPreview);
      setCatalog(nextCatalog.length);
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setBusy(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === "Escape" && !busy) onClose();
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [busy, onClose]);

  const handleConfigure = async () => {
    setConfirming(false);
    setBusy(true);
    setError(null);
    try {
      const text = await setupConfigure();
      setOutput(text || "配置完成。");
      await refresh();
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setBusy(false);
    }
  };

  const joined = Boolean(snapshot?.joined);
  const sessions = snapshot?.locals.length ?? 0;

  return (
    <div className="overlay" role="presentation" onMouseDown={() => !busy && onClose()}>
      <section
        className="sheet setup-sheet"
        role="dialog"
        aria-modal="true"
        aria-label="环境配置"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <header className="sheet-header">
          <h1>环境配置</h1>
          <button type="button" className="sheet-done" onClick={onClose} disabled={busy}>
            完成
          </button>
        </header>

        <div className="setup-section">
          <h2>后台</h2>
          {info ? (
            <>
              <div className="setup-row">
                <TerminalIcon size={14} />
                <span className="setup-path" title={info.path}>
                  {info.path}
                </span>
                <span className="setup-badge">{info.source}</span>
              </div>
              <div className="setup-row">
                <CheckIcon size={14} />
                <span className="setup-version">{info.version}</span>
              </div>
            </>
          ) : (
            <p className="setup-muted">{busy ? "正在检查后台…" : "未找到后台。"}</p>
          )}
        </div>

        <div className="setup-section">
          <h2>已接入工具</h2>
          {agents.length > 0 ? (
            <div className="setup-chips">
              {agents.map((agent) => (
                <span className="setup-chip" key={agent}>
                  {AGENT_LABELS[agent] ?? agent}
                </span>
              ))}
            </div>
          ) : (
            <p className="setup-muted">未检测到已配置的会话工具。</p>
          )}
          <p className="setup-hint">
            支持 Codex、Claude Code、Gemini CLI 和 dsh，配置其中一种即可。写入前可以先看下方预览；
            不会安装额外的后台服务。
          </p>
          <div className="setup-actions">
            {confirming ? (
              <div className="setup-confirm">
                <p>
                  将为已安装的 Codex、Claude Code、Gemini CLI 或 dsh 写入 MCP / hooks
                  配置；使用 --no-service，不安装后台服务。已有其它配置会保留。写入内容以
                  「将写入的配置」为准。
                </p>
                <div className="setup-confirm-actions">
                  <button
                    type="button"
                    className="button primary"
                    onClick={() => void handleConfigure()}
                    disabled={busy}
                  >
                    确认写入
                  </button>
                  <button
                    type="button"
                    className="button"
                    onClick={() => setConfirming(false)}
                    disabled={busy}
                  >
                    取消
                  </button>
                </div>
              </div>
            ) : (
              <button
                type="button"
                className="button"
                onClick={() => setConfirming(true)}
                disabled={busy || !info}
              >
                配置本机工具…
              </button>
            )}
          </div>
        </div>

        <div className="setup-section">
          <h2>连接状态</h2>
          <div className="setup-row">
            <span className="setup-key">Network</span>
            <span className="setup-value">
              {joined
                ? `${snapshot?.networkName ?? "已加入"} · ${snapshot?.person ?? ""}`
                : "尚未加入 Network"}
            </span>
          </div>
          <div className="setup-row">
            <span className="setup-key">本机会话</span>
            <span className="setup-value">{sessions} 个</span>
          </div>
          <div className="setup-row">
            <span className="setup-key">原生会话目录</span>
            <span className="setup-value">{catalog === null ? "—" : `${catalog} 条`}</span>
          </div>
          <p className="setup-hint">
            配置后打开 Codex / Claude Code 的原对话并接入 Network，再点「重新检查」确认会话登记。
          </p>
        </div>

        <div className="setup-section">
          <h2>将写入的配置</h2>
          <pre className="setup-output">{preview || "没有需要变更的配置。"}</pre>
        </div>

        {output && (
          <div className="setup-section">
            <h2>上次配置结果</h2>
            <pre className="setup-output">{output}</pre>
          </div>
        )}

        {error && <p className="form-error">{error}</p>}

        <footer className="setup-footer">
          <button type="button" className="button" onClick={() => void refresh()} disabled={busy}>
            <RefreshIcon size={13} /> 重新检查
          </button>
          <button type="button" className="button primary" onClick={onClose} disabled={busy}>
            完成
          </button>
        </footer>
      </section>
    </div>
  );
}
