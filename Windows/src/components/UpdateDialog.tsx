import { useEffect } from "react";

interface Props {
  currentVersion: string;
  version: string;
  notes?: string;
  installing: boolean;
  percent: number | null;
  error: string | null;
  onInstall: () => void;
  onClose: () => void;
}

export default function UpdateDialog({
  currentVersion,
  version,
  notes,
  installing,
  percent,
  error,
  onInstall,
  onClose,
}: Props) {
  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === "Escape" && !installing) onClose();
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [onClose, installing]);

  return (
    <div className="overlay" role="presentation" onMouseDown={installing ? undefined : onClose}>
      <section
        className="sheet update-sheet"
        role="dialog"
        aria-modal="true"
        aria-label="软件更新"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <header className="sheet-header">
          <h1>软件更新</h1>
          <button type="button" className="sheet-done" disabled={installing} onClick={onClose}>
            关闭
          </button>
        </header>

        <p className="update-versions">
          <strong>{version}</strong>
          <span>当前 {currentVersion}</span>
        </p>

        {notes && <pre className="update-notes">{notes}</pre>}

        {installing ? (
          <div className="update-progress">
            <div className="update-bar">
              <span style={{ width: `${percent ?? 12}%` }} />
            </div>
            <p className="overview-help">
              {percent === null ? "正在下载更新…" : `正在下载更新… ${percent}%`}
            </p>
            <p className="overview-help">安装完成后应用会自动重启。</p>
          </div>
        ) : (
          <div className="overview-actions">
            <button type="button" className="button primary" onClick={onInstall}>
              下载并安装
            </button>
            <button type="button" className="button" onClick={onClose}>
              稍后
            </button>
          </div>
        )}

        {error && <p className="overview-hint">更新失败：{error}</p>}
      </section>
    </div>
  );
}
