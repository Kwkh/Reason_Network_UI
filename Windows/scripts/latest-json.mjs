#!/usr/bin/env node
/**
 * 从 Tauri 的 NSIS 更新包生成 updater 使用的 `latest.json`。
 *
 * 用法：
 *   node scripts/latest-json.mjs --version 0.2.0 --tag windows-v0.2.0 \
 *     [--dir src-tauri/target/release/bundle/nsis] [--out <path>] [--notes-file <file>]
 *
 * 需要 `tauri build` 在 `createUpdaterArtifacts: true` 下产出的安装器和签名：
 * Windows 的更新包就是 NSIS 安装器本身（`*-setup.exe` + `*-setup.exe.sig`）。
 * 默认输出到 bundle 目录下的 `latest.json`。
 */
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");

function arg(name, fallback = null) {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 && process.argv[index + 1] ? process.argv[index + 1] : fallback;
}

const version = arg("version");
const tag = arg("tag");
const dir = resolve(root, arg("dir", "src-tauri/target/release/bundle/nsis"));
const out = resolve(root, arg("out", join(dir, "latest.json")));
const notesFile = arg("notes-file");

if (!version || !tag) {
  console.error("用法：node scripts/latest-json.mjs --version <版本> --tag <标签> [--dir <目录>]");
  process.exit(2);
}
if (!existsSync(dir)) {
  console.error(`找不到打包目录：${dir}`);
  process.exit(2);
}

const installers = readdirSync(dir)
  .filter((name) => name.endsWith(".exe.sig"))
  .map((name) => join(dir, name.slice(0, -".sig".length)))
  .filter((path) => existsSync(path) && statSync(path).isFile())
  .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);

if (installers.length === 0) {
  console.error(
    `目录里没有带签名的安装器（*_setup.exe + *.exe.sig）：${dir}。请用带更新签名的发布构建重新打包。`,
  );
  process.exit(2);
}

const installer = installers[0];
const sigPath = `${installer}.sig`;
const signature = readFileSync(sigPath, "utf8").trim();
const asset = installer.split(/[\\/]/).pop();
const notes = notesFile
  ? readFileSync(resolve(root, notesFile), "utf8").trim()
  : `Reason Network Windows ${version}`;

const manifest = {
  version,
  notes,
  pub_date: new Date().toISOString(),
  platforms: {
    "windows-x86_64": {
      signature,
      url: `https://github.com/Kwkh/Reason_Network_UI/releases/download/${encodeURIComponent(
        tag,
      )}/${encodeURIComponent(asset)}`,
    },
  },
};

writeFileSync(out, `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`已写入 ${out}`);
console.log(`  版本 ${version} · 更新包 ${asset}`);
