import { check, type Update } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";

export interface AvailableUpdate {
  /** 当前运行版本。 */
  currentVersion: string;
  /** 服务器宣布的新版本。 */
  version: string;
  date?: string;
  body?: string;
  /** 插件返回的更新句柄，安装完成后由插件释放。 */
  update: Update;
}

/** 检查 `tauri.conf.json` 里配置的更新端点；没有新版本时返回 null。 */
export async function findUpdate(): Promise<AvailableUpdate | null> {
  const update = await check({ timeout: 15_000 });
  if (!update) return null;
  return {
    currentVersion: update.currentVersion,
    version: update.version,
    date: update.date,
    body: update.body,
    update,
  };
}

/** 下载并安装更新；`onProgress` 收到 0–100 或 null（总大小未知）。 */
export async function installUpdate(
  update: Update,
  onProgress: (percent: number | null) => void,
): Promise<void> {
  let total = 0;
  let downloaded = 0;
  await update.downloadAndInstall((event) => {
    if (event.event === "Started") {
      total = event.data.contentLength ?? 0;
      onProgress(total > 0 ? 0 : null);
    } else if (event.event === "Progress") {
      downloaded += event.data.chunkLength;
      onProgress(total > 0 ? Math.min(100, Math.round((downloaded / total) * 100)) : null);
    } else {
      onProgress(100);
    }
  });
  // Windows 的 NSIS 安装器会接管并退出应用；其余情况（或安装器提前返回）再重启一次。
  await relaunch().catch(() => {
    // 安装器已经结束本进程时重启会失败，属于正常路径。
  });
}
