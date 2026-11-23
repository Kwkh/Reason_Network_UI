# Reason Network · macOS

SwiftUI 原生消息控制台。界面不使用 WebView，不启动浏览器、HTTP 服务或 Python。系统要求 macOS 14+，工程使用 Xcode 26.5 验证。

## 安装与首次配置

从 [GitHub Releases](https://github.com/Kwkh/Reason_Network_UI/releases) 下载 Universal DMG，将 App 拖入 Applications。GitHub 上的 1.1.5 发行包内含 Developer ID 签名并通过 Apple 公证的 App。已有安装请打开「环境配置」，点击「更新兼容后台」启用归档与缺失线程的投递保护。

首次启动自动检查内置兼容后台、登录服务、Codex 接入与 Network 状态；已配置的机器直接进入聊天。新机流程：

1. **安装并配置**：从 App 内安装双架构 `reason-network 0.12.17`，接入代理 MCP / hooks 并启动支持逐会话退出的登录服务。普通用户无需 Rust、Python 或终端。
2. **加入 Network**：在 App 内粘贴邀请链接、完整邀请行或四词一次性代码，填写名称。邀请方需要在线；同一身份的新机器请向原机器获取一次性代码。已有团队不会被替换；状态不明时先重新检查。
3. **进入聊天**：重启 Codex 并在目标对话中发一条消息，会话即可出现。已配置但尚无在线会话时也可进入 UI。

可从右上角状态面板的「环境配置」重新打开引导。安装失败可重试；加入超时后会重新检查成员状态，不自动重发。邀请凭证不保存到偏好设置，错误输出会隐藏完整邀请。

同时支持 `~/.local/bin/reason-network` 和官方 Reason CLI 的 `~/.reason/bin/reason-network`；配置时保留已有同版本 CLI，并备份原登录服务。App 不创建 UI 专属会话，不迁移旧机器的会话或聊天缓存。当前主要面向 Codex，会话本身的即时推送仍由官方接入负责。

## 从源码运行

打开 `Reason Network.xcodeproj`，选择共享 Scheme **Reason Network**，Run。工程使用本机临时签名，不需要 Apple Developer 账号；Icon Composer 资源使用 Xcode 26.5 验证。

```sh
xcodebuild -project 'Reason Network.xcodeproj' -scheme 'Reason Network' -configuration Release -derivedDataPath /tmp/reason-network-build build
./Tests/run-checks.sh
./Tools/package-release.sh /tmp/reason-network-release
```

打包脚本构建 arm64 / x86_64，检查架构与签名，并生成 DMG 和 `.sha256`。打包时也检查内置后台的两种架构和签名。

## 界面与行为

- 使用工具栏的侧栏按钮展开或收起会话列表。侧栏顶部可切换本机会话并查看各自的在线状态。列表按联系人和 Agent 分组，同一台 Mac 上的 Codex 会话可互发消息。右侧标题下方显示收件会话的地址和状态。切换时消息区短暂交叉淡化，并响应系统的减少动态效果设置。这不是读取对方完整聊天或确认其侧边栏标题。
- 右上角在线状态打开设备面板：本机会话选择、push/turn/pull 接收模式、设备名、在线状态、连接方式及延迟；诊断可展开并刷新。
- 消息按本机会话＋队友会话隔离，默认显示最近 100 条，滚到顶部可继续加载，每次最多 100 条；切换时分别保留草稿。Enter 发送、Shift + Enter 换行，⌘ R 刷新；长草稿在输入框内原生滚动。输入框左侧的「＋」可添加 UTF-8 文本附件，或为本条消息请求对方桌面提醒。每条最多 10 个附件，单个上限 256 KiB，合计 512 KiB。点击收到的附件名可在 App 内阅读。
- 目录及消息约每 3 秒更新。App 的显示刷新与 Codex 的即时消息接收是独立机制；它不会把一个 pull 会话伪装为 push。
- 只显示明确收集到的投递结果；已排队／已投递不等于对方已读。超时不自动重发。

## 数据兼容

继续使用网页控制台的 `~/.reason/network/local-ui/messages.sqlite3`，不复制或删除原缓存；同一消息 ID 去重。迁移兼容原 messages 表和 events 表。
Reason 引擎数据库 `~/.reason/network/network.db` 以 SQLite **只读**方式访问。不会调用 Inbox / Delivered，不改变 Codex 未读状态，不自动执行消息文字。
客户端按消息 ID、Network 和会话核对后台收件、待投递发件与发送回执。Codex 日志中的单次发送也可补入历史，包括原生输入通道的回执。首次从现存日志开头扫描，随后增量读取。若远端消息已离开发件队列，且本机没有缓存正文或可识别的发送日志，仅凭回执无法还原正文。
现有官方数据库和日志格式不是稳定公共 API，后续 Reason / Codex 升级可能需要适配。

## 结构

- `ReasonNetworkApp.swift` / `ContentView.swift`：原生窗口与 SwiftUI 控件。
- `SetupService.swift` / `SetupModel.swift` / `SetupView.swift`：环境检查、内置后台安装和首次配置界面。
- `NetworkModel.swift`：主线程可观察状态，防止旧会话响应串入当前聊天。
- `ReasonService.swift`：后台 actor，调用官方 CLI，接入现有缓存；发送前核验本机身份与接收会话。
- `SQLiteStore.swift` / `TranscriptMirror.swift`：原生 SQLite 与只读日志镜像，无第三方运行时。
- `Resources/AppIcon.icon`：当前实际编译的 Icon Composer 分层图标；`Assets/Bubble.svg` 与 `Assets/Prompt.svg` 是 1024×1024 画布的两层前景，`icon.json` 定义背景与材质。`Tools/Icon.swift` 和旧 PNG / ICNS 仅保留作绘制与对比参考。
- `Tests/CoreChecks.swift`：隔离临时目录＋模拟 CLI，检查只读访问、held 消息排除、会话隔离、发送参数／正文、日志增量与半行恢复。不会向真实队友发测试消息。

此配套工具需要访问用户目录内的 CLI、数据库及日志，因此未开启 App Sandbox。正式版使用 Developer ID 分发。Tools/package-release.sh 生成的本地开发包使用临时签名。

## 图标适配检查（2026-11-22）

原 AppIcon PNG 各尺寸均有效，但当前 macOS 对旧格式的处理使圆角白底显示为独立贴片；改为完整不透明 PNG 后仍能复现。当前 Xcode 资源构建阶段已改为 `Resources/AppIcon.icon`，由 actool 编译背景与前景，避免将白色画布作为前景一起缩放。前景不包含底板、预制圆角和阴影；系统生成最终外轮廓。Release Build 7 与严格验签通过，系统“关于”窗口确认双层底板已消除。后续请用 Icon Composer 编辑该 .icon 文件。

图标材质更新：Build 8 使用气泡外框与终端符号两个玻璃组，开启 specular；translucency 分别为 0.22 / 0.18，neutral shadow 分别为 0.38 / 0.44，背景使用浅灰自动渐变。Release 构建、严格验签和实际“关于”窗口显示检查通过。无玻璃版本的资源备份位于原 Websites 工作区 deliverables/reason-network-icon-before-glass.zip。

逐会话退出使用基于官方 0.12.17 的兼容后台。[构建、切换与恢复说明](Engine/README.md)。
