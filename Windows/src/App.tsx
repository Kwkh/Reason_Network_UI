import { useCallback, useEffect, useState } from "react";
import {
  createNetwork,
  joinNetwork,
  listNetworks,
  loadSnapshot,
  openDataFolder,
  sendMessage,
} from "./api";
import type { ChatMessage, NetworkSummary, Snapshot } from "./types";
import Sidebar from "./components/Sidebar";
import ChatView from "./components/ChatView";
import Composer from "./components/Composer";
import JoinDialog from "./components/JoinDialog";

type DialogMode = "join" | "create" | null;

function errorText(cause: unknown): string {
  if (typeof cause === "string") return cause;
  if (cause instanceof Error) return cause.message;
  try {
    return JSON.stringify(cause);
  } catch {
    return String(cause);
  }
}

function summarize(output: string, fallback: string): string {
  try {
    const value = JSON.parse(output) as { team_name?: unknown };
    if (typeof value.team_name === "string" && value.team_name) {
      return `${fallback}：${value.team_name}`;
    }
  } catch {
    // 后台没有返回 JSON 时用兜底文案。
  }
  return fallback;
}

export default function App() {
  const [networks, setNetworks] = useState<NetworkSummary[]>([]);
  const [network, setNetwork] = useState<string | null>(null);
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [local, setLocal] = useState<string | null>(null);
  const [peer, setPeer] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [replyTo, setReplyTo] = useState<ChatMessage | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [dialog, setDialog] = useState<DialogMode>(null);

  // 选中的本机会话可能已经离线消失；此时回退到后台给出的默认会话。
  const localStillThere =
    local !== null && snapshot?.locals.some((session) => session.name === local);
  const effectiveLocal =
    (localStillThere ? local : null) ?? snapshot?.selectedLocal ?? null;
  const effectivePeer = peer ?? snapshot?.selectedPeer ?? null;

  const refreshNetworks = useCallback(async () => {
    try {
      const items = await listNetworks();
      setNetworks(items);
      setNetwork((current) => {
        if (current && items.some((item) => item.id === current)) return current;
        return items.find((item) => item.joined)?.id ?? items[0]?.id ?? null;
      });
    } catch (cause) {
      setError(errorText(cause));
    }
  }, []);

  useEffect(() => {
    void refreshNetworks();
  }, [refreshNetworks]);

  useEffect(() => {
    if (!notice) return;
    const timer = window.setTimeout(() => setNotice(null), 6000);
    return () => window.clearTimeout(timer);
  }, [notice]);

  useEffect(() => {
    if (!network) return;
    let alive = true;

    const tick = async () => {
      try {
        const next = await loadSnapshot(network, local, peer);
        if (!alive) return;
        setSnapshot(next);
        setError(null);
        if (!local && next.selectedLocal) setLocal(next.selectedLocal);
        if (!peer && next.selectedPeer) setPeer(next.selectedPeer);
      } catch (cause) {
        if (alive) setError(errorText(cause));
      }
    };

    void tick();
    const timer = window.setInterval(() => {
      void tick();
    }, 3000);
    return () => {
      alive = false;
      window.clearInterval(timer);
    };
  }, [network, local, peer]);

  const changeNetwork = (id: string) => {
    if (!id || id === network) return;
    setNetwork(id);
    setLocal(null);
    setPeer(null);
    setSnapshot(null);
    setReplyTo(null);
    setDraft("");
  };

  const chooseLocal = (name: string) => {
    setLocal(name);
    setPeer(null);
    setReplyTo(null);
  };

  const choosePeer = (address: string) => {
    setPeer(address);
    setReplyTo(null);
  };

  const refresh = useCallback(async () => {
    setBusy(true);
    try {
      await refreshNetworks();
      if (network) {
        const next = await loadSnapshot(network, local, peer);
        setSnapshot(next);
        if (!local && next.selectedLocal) setLocal(next.selectedLocal);
        if (!peer && next.selectedPeer) setPeer(next.selectedPeer);
      }
      setNotice("已刷新");
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setBusy(false);
    }
  }, [network, local, peer, refreshNetworks]);

  const handleSend = async () => {
    if (!snapshot || !effectiveLocal || !effectivePeer || !draft.trim() || busy) return;
    const sender = snapshot.locals.find((session) => session.name === effectiveLocal);
    if (!sender) {
      setError("本机会话已离线，请刷新后重试。");
      return;
    }
    const target = snapshot.directory.find((session) => session.address === effectivePeer);
    // 同机的收件会话要钉到本机，避免同名地址被另一台设备接走。
    const to =
      target?.isMe && snapshot.machine
        ? `${effectivePeer}@${snapshot.machine}`
        : effectivePeer;
    setBusy(true);
    try {
      const outcome = await sendMessage({
        network,
        from: sender.key,
        to,
        body: draft,
        replyTo: replyTo?.id ?? null,
      });
      setDraft("");
      setReplyTo(null);
      setNotice(outcome.output || "已交给后台发送");
      const next = await loadSnapshot(network, effectiveLocal, effectivePeer);
      setSnapshot(next);
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setBusy(false);
    }
  };

  const handleDialogSubmit = async (fields: {
    invite: string;
    name: string;
    person: string;
  }) => {
    if (!dialog) return;
    const output =
      dialog === "join"
        ? await joinNetwork(network, fields.invite, fields.person)
        : await createNetwork(network, fields.name, fields.person);
    setDialog(null);
    setNotice(summarize(output, dialog === "join" ? "已加入 Network" : "已新建 Network"));
    setLocal(null);
    setPeer(null);
    setSnapshot(null);
    await refreshNetworks();
    const next = await loadSnapshot(network, null, null);
    setSnapshot(next);
  };

  const handleOpenFolder = () => {
    void openDataFolder(network).catch((cause) => setError(errorText(cause)));
  };

  const canCompose = Boolean(snapshot?.joined && effectiveLocal && effectivePeer);

  return (
    <div className="app">
      <Sidebar
        networks={networks}
        network={network}
        snapshot={snapshot}
        local={effectiveLocal}
        peer={effectivePeer}
        busy={busy}
        onNetwork={changeNetwork}
        onLocal={chooseLocal}
        onPeer={choosePeer}
        onJoin={() => setDialog("join")}
        onCreate={() => setDialog("create")}
        onRefresh={() => void refresh()}
        onOpenFolder={handleOpenFolder}
      />

      <div className="workspace">
        <ChatView
          snapshot={snapshot}
          localName={effectiveLocal}
          peer={effectivePeer}
          onReply={(message) => setReplyTo(message)}
          onRefresh={() => void refresh()}
          onJoin={() => setDialog("join")}
          onCreate={() => setDialog("create")}
        />
        <Composer
          value={draft}
          replyTo={replyTo}
          disabled={!canCompose}
          busy={busy}
          onChange={setDraft}
          onSend={() => void handleSend()}
          onCancelReply={() => setReplyTo(null)}
        />
      </div>

      {dialog && (
        <JoinDialog
          key={dialog}
          mode={dialog}
          defaultPerson={snapshot?.person ?? ""}
          onClose={() => setDialog(null)}
          onSubmit={handleDialogSubmit}
        />
      )}

      {(error || notice) && (
        <div className={error ? "toast error" : "toast"} role={error ? "alert" : "status"}>
          <span>{error ?? notice}</span>
          <button
            type="button"
            className="icon-button"
            title="关闭"
            onClick={() => (error ? setError(null) : setNotice(null))}
          >
            ×
          </button>
        </div>
      )}
    </div>
  );
}
