import { useCallback, useEffect, useRef, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { open, save } from "@tauri-apps/plugin-dialog";
import { onAction } from "@tauri-apps/plugin-notification";
import {
  attachmentText,
  createNetwork,
  createWorkspace,
  deleteWorkspace,
  inspectAttachments,
  joinNetwork,
  joinWorkspace,
  listNetworks,
  loadSnapshot,
  networkLink,
  openDataFolder,
  saveAttachment,
  sendMessage,
  setSessionParticipation,
} from "./api";
import type { Attachment, AttachmentDraft, ChatMessage, NetworkSummary, Snapshot } from "./types";
import Sidebar from "./components/Sidebar";
import ChatView from "./components/ChatView";
import Composer from "./components/Composer";
import JoinDialog from "./components/JoinDialog";
import OverviewDialog from "./components/OverviewDialog";
import AttachmentPreview from "./components/AttachmentPreview";
import SetupDialog from "./components/SetupDialog";
import { splitAddress } from "./lib/format";
import { draftKey, persistDraft, readDraft, removeDraft, removeNetworkDrafts } from "./lib/drafts";
import { ensureNotificationPermission, showIncomingToast } from "./lib/notify";

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
  const [pendingReplyId, setPendingReplyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [dialog, setDialog] = useState<DialogMode>(null);
  const [dialogScope, setDialogScope] = useState<"primary" | "workspace">("primary");
  const [overviewOpen, setOverviewOpen] = useState(false);
  const [setupOpen, setSetupOpen] = useState(false);

  // 选中的本机会话可能已经离线消失；此时回退到后台给出的默认会话。
  const localStillThere =
    local !== null && snapshot?.locals.some((session) => session.name === local);
  const effectiveLocal =
    (localStillThere ? local : null) ?? snapshot?.selectedLocal ?? null;
  const effectivePeer = peer ?? snapshot?.selectedPeer ?? null;

  // 草稿按 Network + 本机会话 + 对方会话隔离。
  const conversationKey = draftKey(network, effectiveLocal, effectivePeer);
  const draftKeyRef = useRef<string | null>(null);
  // 桌面通知的基线：切换本机会话时重置，首次看到的历史消息不弹。
  const noticeLocalRef = useRef<string | null>(null);
  const noticeAtRef = useRef<Map<string, number>>(new Map());

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

  // 切换会话：先把旧草稿落盘，再恢复目标会话的正文、附件、提醒开关和回复目标。
  useEffect(() => {
    const previous = draftKeyRef.current;
    if (previous === conversationKey) return;
    if (previous) {
      persistDraft(previous, {
        text: draft,
        files: files.map((file) => file.path),
        notify,
        replyTo: replyTo?.id ?? null,
      });
    }
    draftKeyRef.current = conversationKey;
    const stored = readDraft(conversationKey);
    setDraft(stored?.text ?? "");
    setNotify(stored?.notify ?? false);
    setReplyTo(null);
    setPendingReplyId(stored?.replyTo ?? null);
    setFiles([]);
    if (!stored?.files.length) return;
    const target = conversationKey;
    void (async () => {
      const restored: AttachmentDraft[] = [];
      for (const path of stored.files) {
        try {
          const [file] = await inspectAttachments([path]);
          if (file) restored.push(file);
        } catch {
          // 文件已移动或删除：恢复时跳过。
        }
      }
      // 用会话 key 判断是否已经切走；这个 effect 的依赖包含本地状态，
      // 不能靠 cleanup 取消，否则 setDraft/setFiles 会立刻把它作废。
      if (draftKeyRef.current !== target) return;
      setFiles(restored);
      if (restored.length !== stored.files.length) {
        setNotice("部分草稿附件已不可用，已移除。");
      }
    })();
  }, [conversationKey, draft, files, notify, replyTo]);

  // 输入时去抖写入，避免每个按键都碰 localStorage。
  useEffect(() => {
    if (!conversationKey) return;
    const timer = window.setTimeout(() => {
      persistDraft(conversationKey, {
        text: draft,
        files: files.map((file) => file.path),
        notify,
        replyTo: replyTo?.id ?? null,
      });
    }, 300);
    return () => window.clearTimeout(timer);
  }, [conversationKey, draft, files, notify, replyTo]);

  // 草稿里的回复目标要等对应消息加载后才能还原成完整对象。
  useEffect(() => {
    if (!pendingReplyId) return;
    const message = snapshot?.messages.find((item) => item.id === pendingReplyId);
    if (message) {
      setReplyTo(message);
      setPendingReplyId(null);
    }
  }, [pendingReplyId, snapshot]);

  useEffect(() => {
    void ensureNotificationPermission();
  }, []);

  // 点击通知：聚焦窗口并切到对应会话。
  useEffect(() => {
    let listener: { unregister: () => Promise<void> } | null = null;
    let cancelled = false;
    void onAction((event) => {
      const extra = (event.notification?.extra ?? {}) as {
        network?: unknown;
        local?: unknown;
        peer?: unknown;
      };
      void (async () => {
        try {
          const win = getCurrentWindow();
          await win.show();
          await win.unminimize();
          await win.setFocus();
        } catch {
          // 窗口 API 不可用时至少保留会话切换。
        }
        if (typeof extra.network === "string" && extra.network) setNetwork(extra.network);
        if (typeof extra.local === "string" && extra.local) setLocal(extra.local);
        if (typeof extra.peer === "string" && extra.peer) setPeer(extra.peer);
      })();
    })
      .then((value) => {
        if (cancelled) void value.unregister();
        else listener = value;
      })
      .catch(() => {
        // 通知点击监听不可用（例如缺少权限）时忽略。
      });
    return () => {
      cancelled = true;
      if (listener) void listener.unregister();
    };
  }, []);

  // 轮询发现新的来信时弹系统通知；首次加载只建立基线，不补弹历史。
  useEffect(() => {
    if (!snapshot?.joined || !effectiveLocal) return;
    if (noticeLocalRef.current !== effectiveLocal) {
      // 切换本机会话：以当前最新来信为基线，不补弹历史。
      noticeLocalRef.current = effectiveLocal;
      noticeAtRef.current = new Map(snapshot.incoming.map((item) => [item.peer, item.at]));
      return;
    }
    for (const item of snapshot.incoming) {
      const previous = noticeAtRef.current.get(item.peer);
      noticeAtRef.current.set(item.peer, Math.max(previous ?? 0, item.at));
      if (previous !== undefined && item.at <= previous) continue;
      // 正在看这个会话且窗口有焦点时不打扰。
      if (document.hasFocus() && item.peer === effectivePeer) continue;
      const sender = splitAddress(item.sender).person || item.peer;
      const peerName = splitAddress(item.peer).name || item.peer;
      void showIncomingToast({
        title: `${sender} · ${peerName}`,
        body: item.preview || "新消息",
        extra: { network, local: item.local, peer: item.peer },
      });
    }
  }, [snapshot, effectiveLocal, effectivePeer, network]);

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

  const openDialog = (mode: Exclude<DialogMode, null>, scope: "primary" | "workspace") => {
    setDialogScope(scope);
    setDialog(mode);
  };

  const changeNetwork = (id: string) => {
    if (!id || id === network) return;
    setNetwork(id);
    setLocal(null);
    setPeer(null);
    setSnapshot(null);
    setPreview(null);
    // 草稿由 conversationKey 的变化负责保存/恢复。
  };

  const chooseLocal = (name: string) => {
    setLocal(name);
    setPeer(null);
  };

  const choosePeer = (address: string) => {
    setPeer(address);
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
      removeDraft(conversationKey);
      setDraft("");
      setReplyTo(null);
      setPendingReplyId(null);
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

  const handleSessionParticipation = async (
    session: { name: string; key: string },
    paused: boolean,
  ) => {
    if (!network || busy) return;
    setBusy(true);
    try {
      await setSessionParticipation(network, session.key, paused);
      setNotice(paused ? `已暂停 ${session.name} 的接入` : `已恢复 ${session.name} 的接入`);
      if (paused && effectiveLocal === session.name) {
        setLocal(null);
        setPeer(null);
      }
      const next = await loadSnapshot(
        network,
        paused ? null : session.name,
        paused ? null : effectivePeer,
      );
      setSnapshot(next);
      if (!paused) setLocal(session.name);
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
    if (dialogScope === "workspace") {
      const summary =
        dialog === "join"
          ? await joinWorkspace(fields.invite, fields.person)
          : await createWorkspace(fields.name, fields.person);
      setDialog(null);
      setNotice(`${dialog === "join" ? "已加入工作区" : "已新建工作区"}：${summary.name}`);
      setLocal(null);
      setPeer(null);
      setSnapshot(null);
      setPreview(null);
      await refreshNetworks();
      setNetwork(summary.id);
      const next = await loadSnapshot(summary.id, null, null);
      setSnapshot(next);
      return;
    }
    // 主工作区的入网/建网：工作区已经是某个 Network 的家，不能覆盖。
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

  // 删除独立工作区：后台会先结束该工作区 daemon 再删目录；当前正看着它时切回主工作区。
  const handleDeleteWorkspace = async (id: string) => {
    const target = networks.find((item) => item.id === id);
    const wasCurrent = network === id;
    setBusy(true);
    try {
      if (wasCurrent) {
        // 先切走：轮询会在每次快照时拉起对应工作区的 daemon，留着会占住数据库。
        setDraft("");
        setFiles([]);
        setNotify(false);
        setReplyTo(null);
        setPendingReplyId(null);
        setPreview(null);
        setLocal(null);
        setPeer(null);
        setSnapshot(null);
        setNetwork("primary");
      }
      await deleteWorkspace(id);
      await refreshNetworks();
      if (wasCurrent) {
        const next = await loadSnapshot("primary", null, null);
        setSnapshot(next);
        if (next.selectedLocal) setLocal(next.selectedLocal);
        setPeer(next.selectedPeer ?? null);
      }
      // 等切换 effect 跑完再清理，否则旧草稿可能被重新写回。
      removeNetworkDrafts(id);
      setNotice(`已删除工作区：${target?.name ?? id}`);
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setBusy(false);
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
          onReply={(message) => {
            setPendingReplyId(null);
            setReplyTo(message);
          }}
          onOpenAttachment={(attachment) => void handleOpenAttachment(attachment)}
          onJoin={() => openDialog("join", "primary")}
          onCreate={() => openDialog("create", "primary")}
          onSetup={() => setSetupOpen(true)}
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
          onCancelReply={() => {
            setPendingReplyId(null);
            setReplyTo(null);
          }}
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
            openDialog("join", "primary");
          }}
          onCreate={() => {
            setOverviewOpen(false);
            openDialog("create", "primary");
          }}
          onJoinWorkspace={() => {
            setOverviewOpen(false);
            openDialog("join", "workspace");
          }}
          onCreateWorkspace={() => {
            setOverviewOpen(false);
            openDialog("create", "workspace");
          }}
          onDeleteWorkspace={handleDeleteWorkspace}
          onSessionParticipation={(session, paused) =>
            void handleSessionParticipation(session, paused)
          }
          onSetup={() => {
            setOverviewOpen(false);
            setSetupOpen(true);
          }}
          onRefresh={() => void refresh()}
          onOpenFolder={handleOpenFolder}
          onCopyInvite={() => void handleCopyInvite()}
          onClose={() => setOverviewOpen(false)}
        />
      )}

      {setupOpen && (
        <SetupDialog snapshot={snapshot} onClose={() => setSetupOpen(false)} />
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
          key={`${dialogScope}-${dialog}`}
          mode={dialog}
          scope={dialogScope}
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
