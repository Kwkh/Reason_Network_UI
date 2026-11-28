#!/usr/bin/env node
/**
 * Windows 发布构建：在 `tauri.release.conf.json` 的基础上，根据是否提供更新签名私钥
 * 决定要不要生成更新包（`.nsis.zip` + `.sig`）。
 *
 * Tauri 在 `createUpdaterArtifacts: true` 且没有 `TAURI_SIGNING_PRIVATE_KEY` 时会直接
 * 构建失败；CI 里没有配置 Secrets 时应该退化成“只出普通安装包”，所以这里临时写一份
 * 合并后的配置再构建，构建完删掉。
 */
import { readFileSync, writeFileSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const confPath = join(root, "src-tauri", "tauri.release.conf.json");
const conf = JSON.parse(readFileSync(confPath, "utf8"));
conf.bundle = { ...(conf.bundle ?? {}) };

const signing = Boolean(
  process.env.TAURI_SIGNING_PRIVATE_KEY || process.env.TAURI_SIGNING_PRIVATE_KEY_PATH,
);
if (!signing) {
  conf.bundle.createUpdaterArtifacts = false;
  console.log(
    "[release] 未设置 TAURI_SIGNING_PRIVATE_KEY / TAURI_SIGNING_PRIVATE_KEY_PATH，" +
      "本次只生成普通安装包，不生成更新签名。",
  );
}

const runtime = join(root, "src-tauri", "tauri.release.runtime.json");
writeFileSync(runtime, `${JSON.stringify(conf, null, 2)}\n`);
const result = spawnSync("npx", ["tauri", "build", "--config", runtime], {
  cwd: root,
  stdio: "inherit",
  shell: true,
});
rmSync(runtime, { force: true });
process.exit(result.status ?? 1);
