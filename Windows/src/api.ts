import { invoke } from "@tauri-apps/api/core";
import type { NativeEntry, NetworkSummary, SendOutcome, Snapshot } from "./types";

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
}): Promise<SendOutcome> {
  return invoke<SendOutcome>("send_message", args);
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

export function nativeCatalog(): Promise<NativeEntry[]> {
  return invoke<NativeEntry[]>("native_catalog");
}

export function openDataFolder(network: string | null): Promise<void> {
  return invoke<void>("open_data_folder", { network });
}
