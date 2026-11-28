import { invoke } from "@tauri-apps/api/core";
import type {
  AttachmentDraft,
  BackendInfo,
  NativeEntry,
  NetworkSummary,
  SendOutcome,
  Snapshot,
} from "./types";

export function listNetworks(): Promise<NetworkSummary[]> {
  return invoke<NetworkSummary[]>("list_networks");
}

export function loadSnapshot(
  network: string | null,
  local: string | null,
  peer: string | null,
): Promise<Snapshot> {
  return invoke<Snapshot>("snapshot", { network, local, peer });
}

export function sendMessage(args: {
  network: string | null;
  from: string;
  to: string;
  body: string;
  replyTo: string | null;
  files: string[];
  notify: boolean;
}): Promise<SendOutcome> {
  return invoke<SendOutcome>("send_message", args);
}

export function inspectAttachments(paths: string[]): Promise<AttachmentDraft[]> {
  return invoke<AttachmentDraft[]>("inspect_attachments", { paths });
}

export function attachmentText(
  network: string | null,
  directory: string,
  name: string,
): Promise<string> {
  return invoke<string>("attachment_text", { network, directory, name });
}

export function saveAttachment(
  network: string | null,
  directory: string,
  name: string,
  target: string,
): Promise<void> {
  return invoke<void>("save_attachment", { network, directory, name, target });
}

export function joinNetwork(
  network: string | null,
  invite: string,
  person: string,
): Promise<string> {
  return invoke<string>("join_network", { network, invite, person });
}

export function createNetwork(
  network: string | null,
  name: string,
  person: string,
): Promise<string> {
  return invoke<string>("create_network", { network, name, person });
}

export function networkLink(network: string | null): Promise<string> {
  return invoke<string>("network_link", { network });
}

export function setSessionParticipation(
  network: string | null,
  key: string,
  paused: boolean,
): Promise<void> {
  return invoke<void>("set_session_participation", { network, key, paused });
}

export function enableWorkspaces(network: string | null): Promise<void> {
  return invoke<void>("enable_workspaces", { network });
}

export function createWorkspace(name: string, person: string): Promise<NetworkSummary> {
  return invoke<NetworkSummary>("create_workspace", { name, person });
}

export function joinWorkspace(invite: string, person: string): Promise<NetworkSummary> {
  return invoke<NetworkSummary>("join_workspace", { invite, person });
}

export function nativeCatalog(): Promise<NativeEntry[]> {
  return invoke<NativeEntry[]>("native_catalog");
}

export function backendInfo(): Promise<BackendInfo> {
  return invoke<BackendInfo>("backend_info");
}

export function appIntegrations(): Promise<string[]> {
  return invoke<string[]>("app_integrations");
}

export function setupPreview(): Promise<string> {
  return invoke<string>("setup_preview");
}

export function setupConfigure(): Promise<string> {
  return invoke<string>("setup_configure");
}

export function openDataFolder(network: string | null): Promise<void> {
  return invoke<void>("open_data_folder", { network });
}
