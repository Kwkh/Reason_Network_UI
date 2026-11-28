/**
 * 桌面通知封装。权限只申请一次；发送失败（例如开发环境没有
 * AppUserModelID）时静默降级，不影响消息本身。
 */

import {
  isPermissionGranted,
  requestPermission,
  sendNotification,
} from "@tauri-apps/plugin-notification";

let permission: boolean | null = null;

export async function ensureNotificationPermission(): Promise<boolean> {
  if (permission !== null) return permission;
  try {
    if (await isPermissionGranted()) {
      permission = true;
    } else {
      permission = (await requestPermission()) === "granted";
    }
  } catch {
    permission = false;
  }
  return permission;
}

export interface IncomingToast {
  title: string;
  body: string;
  extra: Record<string, unknown>;
}

export async function showIncomingToast(toast: IncomingToast): Promise<void> {
  if (!(await ensureNotificationPermission())) return;
  try {
    sendNotification({
      title: toast.title,
      body: toast.body,
      extra: toast.extra,
      autoCancel: true,
      group: "reason-network",
    });
  } catch {
    // 通知不可用时静默失败，消息本身不受影响。
  }
}
