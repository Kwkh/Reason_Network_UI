# Reason Network Chat

原生 macOS 聊天窗口，整合 wkh 的 Reason Network UI 和 Samson 的独立控制台。使用系统 SF 与苹方字体，默认白底，可在状态面板切换黑底。沿用 wkh 的原版 Icon Composer 图标。

## 运行

系统要求 macOS 14 或更新版本。本机需要安装并配置官方 Reason Network 引擎，可执行文件通常在 `~/.local/bin/reason-network` 或 `~/.reason/bin/reason-network`。以 Codex 身份发送时，该会话还需要已接入 Reason Network。

解压 App 后可直接打开。App 使用本机临时签名，尚未进行 Apple 公证。其 App 标识与两个原版分开，可以并存。打开源代码中的 `Reason Network.xcodeproj`，选择共享 Scheme **Reason Network** 即可构建。

```sh
xcodebuild -project 'Reason Network.xcodeproj' -scheme 'Reason Network' -configuration Release -derivedDataPath /tmp/reason-network-chat-build build
./Tests/run-checks.sh
```

## 操作

- 左侧栏可直接展开联系人和 Agent，再选择对话。⌘K 聚焦侧栏搜索，搜索时自动展开匹配项。对话保留最近消息预览和未读数。
- 右上角查看在线设备、连接方式、延迟和接收方式，也可以切换本机发送身份。选择「独立控制台」后沿用旧版的 `console` 收件箱。
- 输入区可添加 UTF-8 文本附件。每次最多 10 个，单个最多 256 KB，合计最多 512 KB。发送选项可控制是否唤醒队友会话、是否在队友电脑弹窗提醒。
- ⌘ Return 发送，⌘ R 刷新。不同本机与队友会话有各自的草稿、附件和发送选项。历史区先显示最近 100 条，可继续加载更早的记录。接收的附件可在 Finder 中查看位置。
- 侧栏底部可打开概览、会话目录和设置，也可用 ⌘1、⌘2、⌘4 打开，按 ⌘3 返回聊天。
- 概览显示账号验证状态、在线会话、设备和控制台未读。会话目录按联系人和 Agent 分组，支持离线筛选、查看设备与项目详情和复制会话地址。
- 设置可查看引擎版本、中继和 UDP 端口、后台日志，运行并复制诊断，或复制邀请链接、重启服务、修复接入。重启和修复会先确认。

## 数据

- 继续使用 wkh 版的 `~/.reason/network/local-ui/messages.sqlite3`，首次打开时升级缓存结构并保留原有记录。
- App 打开时同步独立控制台，并读取旧控制台的 `~/Library/Application Support/Reason Network Console/history.json` 中与当前网络 ID 匹配的记录。新消息持久化后才确认收取，打开该对话才清除 App 未读标记。关闭 App 时只结束控制台会话，Reason Network 服务继续运行。
- Codex 身份的收件记录从引擎数据库只读获取，打开界面不会改变 Codex 的未读状态。已发记录只读取支持的成功发送日志，复杂工具调用和较早日志可能不完整。
- App 依赖官方 CLI 和本机守护进程。数据库及日志格式随版本变化时可能需要适配。附件由引擎保留，过期后界面仍可能显示文件名。

`Tests/run-checks.sh` 使用临时目录、模拟 CLI 和模拟 Unix socket，覆盖缓存升级、旧独立控制台历史导入、双身份、附件、发送参数、管理命令、未读标记、历史分页和 Codex 收件记录只读访问。已构建的 App 可用 `Contents/MacOS/Reason Network Chat --self-test` 检查本机服务。
