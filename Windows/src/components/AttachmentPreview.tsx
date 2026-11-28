import { useEffect } from "react";

interface Props {
  name: string;
  text: string;
  onSave: () => void;
  onClose: () => void;
}

export default function AttachmentPreview({ name, text, onSave, onClose }: Props) {
  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [onClose]);

  return (
    <div className="overlay" role="presentation" onMouseDown={onClose}>
      <section
        className="sheet attachment-preview"
        role="dialog"
        aria-modal="true"
        aria-label={`附件 ${name}`}
        onMouseDown={(event) => event.stopPropagation()}
      >
        <header className="sheet-header">
          <h1 title={name}>{name}</h1>
          <button type="button" className="sheet-done" onClick={onClose}>
            完成
          </button>
        </header>
        <pre className="preview-body">{text || "（空文件）"}</pre>
        <footer className="preview-actions">
          <span className="preview-meta">只读预览 · 文本附件</span>
          <button type="button" className="button" onClick={onSave}>
            另存为…
          </button>
        </footer>
      </section>
    </div>
  );
}
