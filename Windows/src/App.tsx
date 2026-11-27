import { useCallback, useEffect, useState } from "react";
import { open, save } from "@tauri-apps/plugin-dialog";
import {
  attachmentText,
  createNetwork,
  inspectAttachments,
  joinNetwork,
  listNetworks,
  loadSnapshot,
  networkLink,
  openDataFolder,
  saveAttachment,
  sendMessage,
} from "./api";
import type { Attachment, AttachmentDraft, ChatMessage, NetworkSummary, Snapshot } from "./types";
import Sidebar from "./components/Sidebar";
import ChatView from "./components/ChatView";
import Composer from "./components/Composer";
import JoinDialog from "./components/JoinDialog";
import OverviewDialog from "./components/OverviewDialog";
import AttachmentPreview from "./components/AttachmentPreview";

type DialogMode = "join" | "create" | null;

async function copyText(text: string): Promise<void> {
  try {
    await navigator.clipboard.writeText(text);
    return;
  } catch {
    // WebView 的剪贴板权限可能被拒绝，退回 execCommand。
  }
  const area = document.createElement("textarea");
  area.value = text;
  area.style.position = "fixed";
  area.style.opacity = "0";
  document.body.appendChild(area);
  area.select();
  document.execCommand("copy");
  area.remove();
}

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
  const [files, setFiles] = useState<AttachmentDraft[]>([]);
  const [notify, setNotify] = useState(false);
  const [preview, setPreview] = useState<{ attachment: Attachment; text: string } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [dialog, setDialog] = useState<DialogMode>(null);
  const [overviewOpen, setOverviewOpen] = useState(false);

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
    setFiles([]);
    setNotify(false);
    setPreview(null);
  };

  const chooseLocal = (name: string) => {
    setLocal(name);
    setPeer(null);
    setReplyTo(null);
    // 附件属于具体会话；切换时丢弃，避免误发给另一个收件人。
    setFiles([]);
  };

  const choosePeer = (address: string) => {
    setPeer(address);
    setReplyTo(null);
    setFiles([]);
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
    if (
      !snapshot ||
      !effectiveLocal ||
      !effectivePeer ||
      (!draft.trim() && files.length === 0) ||
      busy
    )
      return;
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
        files: files.map((file) => file.path),
        notify,
      });
      setDraft("");
      setReplyTo(null);
      setFiles([]);
      setNotify(false);
      setNotice(outcome.output || "已交给后台发送");
      const next = await loadSnapshot(network, effectiveLocal, effectivePeer);
      setSnapshot(next);
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setBusy(false);
    }
  };

  const handlePickFiles = async () => {
    try {
      const picked = await open({ multiple: true, title: "添加文本附件" });
      if (!picked) return;
      const paths = Array.isArray(picked) ? picked : [picked];
      const existing = new Set(files.map((file) => file.path.toLowerCase()));
      const additions = paths.filter((path) => !existing.has(path.toLowerCase()));
      if (additions.length === 0) return;
      if (files.length + additions.length > 10) {
        setError("每条消息最多添加 10 个附件。");
        return;
      }
      setBusy(true);
      const drafts = await inspectAttachments([
        ...files.map((file) => file.path),
        ...additions,
      ]);
      setFiles(drafts);
      setError(null);
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setBusy(false);
    }
  };

  const handleRemoveFile = (path: string) => {
    setFiles((current) => current.filter((file) => file.path !== path));
  };

  const handleOpenAttachment = async (attachment: Attachment) => {
    const directory = attachment.directory;
    if (!directory) return;
    try {
      const text = await attachmentText(network, directory, attachment.name);
      setPreview({ attachment, text });
    } catch (cause) {
      setError(errorText(cause));
    }
  };

  const handleSavePreview = async () => {
    const current = preview;
    const directory = current?.attachment.directory;
    if (!current || !directory) return;
    try {
      const target = await save({
        title: "保存附件",
        defaultPath: current.attachment.name,
      });
      if (!target) return;
      await saveAttachment(network, directory, current.attachment.name, target);
      setNotice("附件已保存");
    } catch (cause) {
      setError(errorText(cause));
    }
  };

  const handleDialogSubmit = async (fields: {
    invite: string;
    name: string;
    person: string;
  }) => {
    if (!dialog) return;
    // 新入网/建网只写主工作区：工作区已经是某个 Network 的家，不能覆盖。
    const output =
      dialog === "join"
        ? await joinNetwork(null, fields.invite, fields.person)
        : await createNetwork(null, fields.name, fields.person);
    setDialog(null);
    setNotice(summarize(output, dialog === "join" ? "已加入 Network" : "已新建 Network"));
    setLocal(null);
    setPeer(null);
    setSnapshot(null);
    await refreshNetworks();
    setNetwork("primary");
    const next = await loadSnapshot("primary", null, null);
    setSnapshot(next);
  };

  const handleOpenFolder = () => {
    void openDataFolder(network).catch((cause) => setError(errorText(cause)));
  };

  const handleCopyInvite = async () => {
    try {
      const link = await networkLink(network);
      await copyText(link);
      setNotice("邀请链接已复制");
    } catch (cause) {
      setError(errorText(cause));
    }
  };

  const canCompose = Boolean(snapshot?.joined && effectiveLocal && effectivePeer);

  return (
    <div className="app">
      <Sidebar
        snapshot={snapshot}
        local={effectiveLocal}
        peer={effectivePeer}
        onLocal={chooseLocal}
        onPeer={choosePeer}
        onOverview={() => setOverviewOpen(true)}
      />

      <div className="workspace">
        <ChatView
          snapshot={snapshot}
          localName={effectiveLocal}
          peer={effectivePeer}
          onReply={(message) => setReplyTo(message)}
          onOpenAttachment={(attachment) => void handleOpenAttachment(attachment)}
          onJoin={() => setDialog("join")}
          onCreate={() => setDialog("create")}
          onStatus={() => setOverviewOpen(true)}
        />
        <Composer
          value={draft}
          replyTo={replyTo}
          files={files}
          notify={notify}
          disabled={!canCompose}
          busy={busy}
          onChange={setDraft}
          onSend={() => void handleSend()}
          onCancelReply={() => setReplyTo(null)}
          onPickFiles={() => void handlePickFiles()}
          onRemoveFile={handleRemoveFile}
          onToggleNotify={() => setNotify((current) => !current)}
        />
      </div>

      {overviewOpen && (
        <OverviewDialog
          networks={networks}
          network={network}
          snapshot={snapshot}
          busy={busy}
          onSelectNetwork={changeNetwork}
          onJoin={() => {
            setOverviewOpen(false);
            setDialog("join");
          }}
          onCreate={() => {
            setOverviewOpen(false);
            setDialog("create");
          }}
          onRefresh={() => void refresh()}
          onOpenFolder={handleOpenFolder}
          onCopyInvite={() => void handleCopyInvite()}
          onClose={() => setOverviewOpen(false)}
        />
      )}

      {preview && (
        <AttachmentPreview
          name={preview.attachment.name}
          text={preview.text}
          onSave={() => void handleSavePreview()}
          onClose={() => setPreview(null)}
        />
      )}

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
