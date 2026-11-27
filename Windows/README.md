# Reason Network · Windows 客户端

Tauri v2 + React + TypeScript 的 Windows 桌面客户端。第一阶段只做后台链路验收需要的
最小界面：切换 Network、选择本机会话、查看对话、收发消息、按原消息回复、加入/新建
Network。

## 依赖

- Node.js 20+ 与 npm
- Rust（MSVC 工具链）、Visual Studio C++ 生成工具、Windows SDK
- WebView2（Windows 11 自带）
- 后台：先运行 `../Engine/build-windows.ps1`，或设置 `REASON_NETWORK_BIN` 指向
  `reason-network.exe`

## 开发

```powershell
cd Windows
npm install
npm run build          # TypeScript 类型检查 + Vite 生产构建，不需要 Rust
npm run tauri:dev      # 启动桌面窗口（需要 Rust/WebView2 和后台二进制）
```

后台查找顺序：

1. `REASON_NETWORK_BIN`
2. 仓库根的 `Engine\Bin\reason-network-backend.exe`
3. `PATH` 里的 `reason-network.exe`

首次使用前，先给检测到的工具写入 MCP/hooks，并打开 Codex 原对话让会话登记：

```powershell
..\Engine\Bin\reason-network-backend.exe setup --no-service
```

## 打包

```powershell
npm run tauri:build
```

产物在 `src-tauri/target/release/bundle/nsis/`。打包不会自动附带后台二进制；
发布前需把 `Engine\Bin\reason-network-backend.exe` 放进安装包资源或用
`REASON_NETWORK_BIN` 指定，后续阶段再补安装器集成。

## 数据与安全

- 只读打开 `~/.reason/network/network.db`（额外工作区在
  `~/.reason/workspaces/<id>/`），不调用 Inbox / Delivered，不改变 Codex 未读状态。
- 收发、入网、目录全部走 `reason-network` CLI，和 macOS 客户端使用同一条后台命令
  路径；客户端不自己实现命名管道协议。
- 界面轮询 3 秒；消息按「本机会话 + 对方会话」隔离，默认显示最近 200 条。

## 第一阶段限制

- 不做附件选择/下载（历史消息里的附件名会显示）。
- 不做每个会话独立草稿、通知、中文输入法以外的桌面集成。
- 不做会话暂停/恢复和环境配置向导；这些仍在原工具与后台侧完成。
- 多工作区切换依赖 `~/.reason/workspaces` 下已有的数据库；在主工作区创建/加入
  Network 已支持，工作区可先用 CLI 入网（见 `../WINDOWS.md`）。
- Windows 下 `codex queue --resume` 警告后的直接控制套接字重试未启用；消息仍会
  排队，打开原线程即可继续。
- 完整安装包、自动更新和安装器内置后台在后续阶段。
