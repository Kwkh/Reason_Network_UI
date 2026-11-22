# Reason Network · macOS

SwiftUI 原生消息控制台。界面不使用 WebView，不启动浏览器、HTTP 服务或 Python。系统要求 macOS 14+，工程使用 Xcode 26.5 验证。

## 运行

打开 `Reason Network.xcodeproj`，选择共享 Scheme **Reason Network**，Run。
工程默认使用本机临时签名，不需要修改 Apple Developer 账号或生成证书。

本机需要已经安装并配置 `~/.local/bin/reason-network`，Codex 会话需要已接入 Reason Network。App 不代替官方后台服务，也不创建新的 UI 身份。

```sh
xcodebuild -project 'Reason Network.xcodeproj' -scheme 'Reason Network' -configuration Release -derivedDataPath /tmp/reason-network-build build
./Tests/run-checks.sh
```

## 界面与行为

- 左上角切换队友会话，优先显示公开的 doing 标题，下方保留地址。这不是读取对方完整聊天或确认其侧边栏标题。
- 右上角在线状态打开设备面板：本机会话选择、push/turn/pull 接收模式、设备名、在线状态、连接方式及延迟；诊断可展开并刷新。
- 消息按本机会话＋队友会话隔离，最近 100 条可见；切换时分别保留草稿。⌘ Return 发送，⌘ R 刷新。
- 目录及消息约每 3 秒更新。App 的显示刷新与 Codex 的即时消息接收是独立机制；它不会把一个 pull 会话伪装为 push。
- 只显示明确收集到的投递结果；已排队／已投递不等于对方已读。超时不自动重发。

## 数据兼容

继续使用网页控制台的 `~/.reason/network/local-ui/messages.sqlite3`，不复制或删除原缓存；同一消息 ID 去重。迁移兼容原 messages 表和 events 表。
Reason 引擎数据库 `~/.reason/network/network.db` 以 SQLite **只读**方式访问。不会调用 Inbox / Delivered，不改变 Codex 未读状态，不自动执行消息文字。
只从 Codex JSONL 中镜像确认成功的 Reason send 工具记录，不展示普通聊天、文件或提示词。支持直接 MCP 调用及单次字面量参数 exec 调用；不求值变量、模板或任意代码。初次读取各日志末尾 8 MB，复杂调用、缺失／压缩日志和更早记录可能不完整。
现有官方数据库和日志格式不是稳定公共 API，后续 Reason / Codex 升级可能需要适配。

## 结构

- `ReasonNetworkApp.swift` / `ContentView.swift`：原生窗口与 SwiftUI 控件。
- `NetworkModel.swift`：主线程可观察状态，防止旧会话响应串入当前聊天。
- `ReasonService.swift`：后台 actor，调用官方 CLI，接入现有缓存；发送前核验本机身份与接收会话。
- `SQLiteStore.swift` / `TranscriptMirror.swift`：原生 SQLite 与只读日志镜像，无第三方运行时。
- `Resources/AppIcon.icon`：当前实际编译的 Icon Composer 分层图标；`Assets/Bubble.svg` 与 `Assets/Prompt.svg` 是 1024×1024 画布的两层前景，`icon.json` 定义背景与材质。`Tools/Icon.swift` 和旧 PNG / ICNS 仅保留作绘制与对比参考。
- `Tests/CoreChecks.swift`：隔离临时目录＋模拟 CLI，检查只读访问、held 消息排除、会话隔离、发送参数／正文、日志增量与半行恢复。不会向真实队友发测试消息。

此本机配套工具需要访问用户目录内已配置的 CLI、数据库及日志，因此未开启 App Sandbox；仅供本机临时签名运行，不是已经完成公证或 App Store 发布的安装包。

## 图标适配检查（2026-11-22）

原 AppIcon PNG 各尺寸均有效，但当前 macOS 对旧格式的处理使圆角白底显示为独立贴片；改为完整不透明 PNG 后仍能复现。当前 Xcode 资源构建阶段已改为 `Resources/AppIcon.icon`，由 actool 编译背景与前景，避免将白色画布作为前景一起缩放。前景不包含底板、预制圆角和阴影；系统生成最终外轮廓。Release Build 7 与严格验签通过，系统“关于”窗口确认双层底板已消除。后续请用 Icon Composer 编辑该 .icon 文件。

图标材质更新：Build 8 使用气泡外框与终端符号两个玻璃组，开启 specular；translucency 分别为 0.22 / 0.18，neutral shadow 分别为 0.38 / 0.44，背景使用浅灰自动渐变。Release 构建、严格验签和实际“关于”窗口显示检查通过。无玻璃版本的资源备份位于原 Websites 工作区 deliverables/reason-network-icon-before-glass.zip。
