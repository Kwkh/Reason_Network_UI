# Reason Network · Windows 客户端

Tauri v2 + React + TypeScript 的 Windows 桌面客户端。支持切换 Network、选择本机会话、
查看对话、收发消息、按原消息回复、加入/新建 Network、UTF-8 文本附件的发送/预览/另存、
每会话草稿和新的来信桌面通知，以及独立工作区的创建/加入与本机会话的暂停/恢复。

## 界面

视觉和结构对齐 macOS 的 SwiftUI 客户端（`Sources/ContentView.swift`）：

- `NavigationSplitView` 双栏：220px 会话侧栏 + 详情；窄窗口降到 185px。
- 侧栏顶部是本机会话菜单（18px semibold + 在线状态点），下面是搜索框；会话按
  person → agent 分组，可折叠；历史会话单独成组。
- 详情顶部是居中的会话标题、等宽地址和状态胶囊；消息用 `labelColor` 4.5%/9% 的
  透明气泡，圆角 13，左侧/右侧对齐。
- 输入区悬浮在消息之上，圆角 22，material 背景 + 细边框 + 轻阴影；圆形发送按钮。
- 输入区左侧「＋」选择文本附件，选中后显示可移除的 chips；旁边的铃铛为本条消息
  请求对方桌面提醒（`--notify`）。收到的附件名可点击预览，并可另存为。
- 每个「本机会话 + 对方会话」各自保存正文、待发附件、提醒开关和回复目标；切换会话
  或重启客户端后自动恢复。
- 轮询发现新的来信时弹 Windows 通知；正在查看该会话且窗口有焦点时不打扰，首次加载
  不补弹历史。点击通知会聚焦窗口并切到对应会话（Windows 仅在 toast 显示期间上报点击）。
- 左侧底部齿轮打开「概览」sheet：切换 Network、复制邀请、加入/新建、刷新、打开数据
  目录、在线会话/设备统计、设备列表，以及工作区和本机会话接入管理。
- 「工作区」可以在不改动主工作区的情况下新建或加入另一个 Network，仍用顶部菜单切换。
- 「本机会话接入」可以暂停/恢复单个会话；暂停后它从侧栏消失，恢复后重新出现。

`src-tauri/windows-app-manifest.xml` 声明 Per-Monitor V2 DPI 感知，避免 150%/200%
缩放下 WebView 视口偏小或裁切。

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

Debug 构建也不弹控制台窗口；需要在终端看 Rust 输出时，临时删掉
`src-tauri/src/main.rs` 里的 `#![windows_subsystem = "windows"]` 再运行。

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
- 附件只读取收件箱 `<home>/inbox/<ULID>/<name>`：校验 26 位 Crockford Base32 目录、
  文件名不含路径分隔符，并用 `canonicalize` 防止符号链接逃出收件箱。
- 草稿保存在 WebView 的 `localStorage`（键前缀 `rn.draft.v1.`），不写入引擎数据库；
  输入后 300ms 落盘，异常强制结束进程可能丢失最后一小段输入。
- 暂停/恢复和 `enable_workspaces` 没有 CLI 子命令，客户端直接连引擎命名管道
  `\\.\pipe\reason-network-<FNV-1a(home)>`：发送一行 JSON，并校验管道对端 PID 与
  `daemon.lock` 一致。工作区目录里的 `workspace-id` 记录团队 id，用于菜单和 `home_for` 定位。
- 界面轮询 3 秒；消息按「本机会话 + 对方会话」隔离，默认显示最近 200 条。

## 第一阶段限制

- 附件仅支持 UTF-8 文本：单个不超过 256 KiB、每条合计 512 KiB、最多 10 个；不做
  二进制文件传输。发件记录只保留文件名，只有收到的附件可以预览/另存。
- 通知依赖应用的 AppUserModelID；未安装的开发构建可能显示为宿主进程名（如
  Windows PowerShell），安装包会显示 “Reason Network”。
- 工作区只支持新建/加入/切换；归档和删除工作区尚未提供，删除目录前需要自行停止该工作区的 daemon。
- 不做环境配置向导；这些仍在原工具与后台侧完成。
- 多工作区切换依赖 `~/.reason/workspaces` 下已有的数据库；在主工作区创建/加入
  Network 已支持，概览里的 Network 菜单可切换已有工作区，工作区可先用 CLI 入网
  （见 `../WINDOWS.md`）。
- Windows 的 Codex 控制套接字是 WinSock AF_UNIX：`resume_queued` 在阻塞线程里用
  `uds_windows` + 同步 WebSocket 客户端完成 `initialize`/`thread/resume`；连接失败时
  仍回落到“消息已排队，打开原线程即可继续”。真实 Codex 的端到端唤醒尚需手工联调。
- 完整安装包、自动更新和安装器内置后台在后续阶段。
