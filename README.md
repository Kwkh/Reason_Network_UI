<img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="" width="80">

# Reason Network for macOS

**让不同工具里的编程对话直接互发消息。** 在 Mac 上选择发送会话和收件会话，就能让本机的 Codex 与 dsh 配合，也能把问题发给队友 Mac 上的 Claude Code。回复会回到发起消息的 Network 和会话。

[下载 1.2.4 Universal DMG](https://github.com/Kwkh/Reason_Network_UI/releases/download/v1.2.4/Reason-Network-1.2.4-macOS-universal.dmg) · [所有正式版](https://github.com/Kwkh/Reason_Network_UI/releases) · [版本记录](https://github.com/Kwkh/Reason_Network_UI/blob/v1.2.4/CHANGELOG.md)

macOS 14 及以上 · Apple 芯片与 Intel · 原生 SwiftUI · 简体中文与英文。正式安装包中的 App 已使用 Developer ID 签名并通过 Apple 公证。

## 两个对话怎样配合？

假设你在 Codex 里写客户端，队友在 Claude Code 里维护服务端。你可以让当前对话发一句「请确认这个接口在没有结果时返回空数组还是 204」。当队友的原对话在线、即时推送通道就绪时，它能在已有的服务端上下文中收到问题，并通过 Reason Network 回信。你可以在 App 里看到这次往返，以及后台确认的投递状态。

## 正式版可以做什么

| 场景 | 在 App 中的操作 |
| --- | --- |
| 同时参与几个项目 | 从「概览」创建或切换 Network。同一个原对话可以加入多个 Network，各自保留成员目录和聊天记录。 |
| 在同一台 Mac 上组织多个对话 | 从侧栏顶部选择本机发送身份，再按人员、工具和会话找到收件方。聊天标题下方显示对方的地址和状态。 |
| 决定何时接收消息 | 为已接入的会话选择即时推送或手动接收。菜单栏的 Connect 和 Receive 可批量管理当前 Network 的连接和接收模式。 |
| 交换开发资料 | 随消息发送日志、Markdown 或配置片段等文本附件，在 App 内读取。侧栏切换对话后，可继续编辑各自的草稿。 |
| 管理成员和历史 | 创建者可以移除设备或解散 Network。对于符合清理条件的历史会话，可删除这台 Mac 上的聊天记录。 |

### Agent 支持

Codex、Claude Code、Gemini CLI 和 DeepSeek Harness（dsh）均支持将原对话加入指定 Network 并收发消息。**向原对话即时推送**已适配 Codex、Claude Code 和 dsh，实际可用性取决于该对话的接收通道；Gemini CLI 可使用手动接收。普通推送使用短回信地址，即使同一个会话加入了两个 Network，回复也能关联到原消息。

## 第一次使用

1. 下载 DMG，把 **Reason Network.app** 拖入「应用程序」并打开。在「环境配置」按提示安装后台并配置你使用的工具。
2. 在「概览」创建自己的 Network，或用队友提供的邀请加入。使用邀请时，请让邀请方保持在线。
3. 打开「我的会话」，选择要接入的原对话。也可以在已配置的工具中直接说「把当前对话加入我的项目 Network」。
4. 从侧栏顶部选定发送身份，点选收件会话，发送第一条消息。想让消息进入对方的原对话时，检查收件会话的在线状态和接收模式。

## 开发与构建

上面的功能说明对应正式版 1.2.4。要复现发行版，请检出 `v1.2.4`；默认分支 `main` 独立开发，界面与正式版可能有所不同。

打开 `Reason Network.xcodeproj`，选择共享 Scheme **Reason Network**，Run。工程使用本机临时签名，不需要 Apple Developer 账号；Icon Composer 资源使用 Xcode 26.5 验证。

```sh
xcodebuild -project 'Reason Network.xcodeproj' -scheme 'Reason Network' -configuration Release -derivedDataPath /tmp/reason-network-build build
./Tests/run-checks.sh
./Tools/package-release.sh /tmp/reason-network-release
```

打包脚本构建 arm64 / x86_64，检查架构与签名，并生成 DMG 和 `.sha256`。打包时也检查内置后台的两种架构和签名。

本地打包脚本生成开发签名的 DMG。正式分发请使用页面顶部的 Release 下载入口。[后台构建与恢复说明](Engine/README.md)
