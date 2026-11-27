import { useEffect, useState } from "react";
import type { FormEvent } from "react";
import { CloseIcon } from "./Icons";

interface Fields {
  invite: string;
  name: string;
  person: string;
}

interface Props {
  mode: "join" | "create";
  defaultPerson: string;
  onClose: () => void;
  onSubmit: (fields: Fields) => Promise<void>;
}

export default function JoinDialog({ mode, defaultPerson, onClose, onSubmit }: Props) {
  const [invite, setInvite] = useState("");
  const [name, setName] = useState("");
  const [person, setPerson] = useState(defaultPerson);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === "Escape" && !busy) onClose();
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [busy, onClose]);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    setError(null);
    setBusy(true);
    try {
      await onSubmit({ invite: invite.trim(), name: name.trim(), person: person.trim() });
    } catch (cause) {
      setError(String(cause));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="overlay" role="presentation">
      <form className="dialog" onSubmit={submit}>
        <header className="dialog-header">
          <h2>{mode === "join" ? "加入 Network" : "新建 Network"}</h2>
          <button
            type="button"
            className="icon-button"
            title="关闭"
            onClick={onClose}
            disabled={busy}
          >
            <CloseIcon />
          </button>
        </header>

        <p className="dialog-help">
          {mode === "join"
            ? "粘贴完整邀请链接或邀请行。邀请方需要在线；Windows 端会使用临时测试身份加入。"
            : "在本机创建一个临时 Network，把邀请链接发给 Mac 端就能开始联调。"}
        </p>

        {mode === "join" ? (
          <label className="field">
            <span>邀请链接 / 邀请行</span>
            <textarea
              value={invite}
              onChange={(event) => setInvite(event.target.value)}
              placeholder="https://… 或 Join the Reason Network: https://…"
              rows={3}
              autoFocus
            />
          </label>
        ) : (
          <label className="field">
            <span>Network 名称</span>
            <input
              value={name}
              onChange={(event) => setName(event.target.value)}
              placeholder="例如 Windows-QA"
              autoFocus
            />
          </label>
        )}

        <label className="field">
          <span>本机名称</span>
          <input
            value={person}
            onChange={(event) => setPerson(event.target.value)}
            placeholder="例如 alice-win"
          />
        </label>

        {error && <p className="form-error">{error}</p>}

        <div className="dialog-actions">
          <button type="button" onClick={onClose} disabled={busy}>
            取消
          </button>
          <button
            type="submit"
            className="primary"
            disabled={busy || person.trim().length === 0 || (mode === "join" ? invite.trim().length === 0 : name.trim().length === 0)}
          >
            {busy ? "请稍候…" : mode === "join" ? "加入" : "创建"}
          </button>
        </div>
      </form>
    </div>
  );
}
