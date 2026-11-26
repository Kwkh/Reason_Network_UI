<img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="" width="80">

# Reason Network for macOS

[简体中文](README.md) · **English**

Send messages between coding sessions on your Mac or a teammate’s device. Choose the sending session and recipient in the sidebar. Replies return to the original conversation in the right Network.

[Download the universal Mac app](https://github.com/Kwkh/Reason_Network_UI/releases/download/v1.2.4/Reason-Network-1.2.4-macOS-universal.dmg) · [All releases](https://github.com/Kwkh/Reason_Network_UI/releases) · [Changelog (Chinese)](https://github.com/Kwkh/Reason_Network_UI/blob/v1.2.4/CHANGELOG.md)

Requires macOS 14 or later. The release includes a Developer ID–signed, Apple-notarized app for Apple silicon and Intel Macs. The native SwiftUI interface supports English and Simplified Chinese.

## How two sessions work together

Suppose you’re building a client in Codex and a teammate maintains the server in Claude Code. Ask their session “Does this endpoint return an empty array or HTTP 204 when there are no results?” With the original session online and Push ready, it can answer using its existing project context. Reason Network shows the exchange and its confirmed delivery status.

## What you can do

- **Switch projects.** Create and switch Networks from the overview. One session can join multiple Networks, each with its own members and chat history.
- **Choose who speaks.** Pick your sending session at the top of the sidebar. Browse recipients by person and tool, then check the address and session status below the chat title.
- **Control delivery.** Choose Push or manual receipt per session. The Connect and Receive menus apply bulk actions to the current Network.
- **Share working material.** Send text attachments such as logs, Markdown and configuration snippets. Drafts stay with their conversations.
- **Manage membership and history.** A Network creator can remove devices or dissolve the Network. Eligible historical conversations can be cleared from this Mac.

Codex, Claude Code, Gemini CLI and DeepSeek Harness (dsh) can join a Network and exchange messages. Codex, Claude Code and dsh support Push into the original conversation when its receive channel is ready. Gemini CLI supports manual receipt. Ordinary pushes include a short reply address that identifies the original message across Networks.

## Send your first message

1. Open the DMG, drag Reason Network into Applications and launch it. Follow Environment Setup to install the background service and configure your agent tool.
2. Create a Network in the overview or join using a teammate’s invitation. The inviter should be online.
3. Choose the original conversation in My Sessions. You can also ask a configured agent to join a Network by name from that conversation.
4. Select a sender and recipient in the sidebar and send a message. For immediate delivery into the original conversation, check the recipient’s status and receive mode.

## Build from source

This guide describes release 1.2.4. Check out tag `v1.2.4` to reproduce that version. Development on `main` proceeds independently.

Open `Reason Network.xcodeproj` in Xcode, select the **Reason Network** scheme and run it. Local builds use ad hoc signing and require no Apple Developer account. The Icon Composer assets were verified with Xcode 26.5.

```sh
xcodebuild -project 'Reason Network.xcodeproj' -scheme 'Reason Network' -configuration Release -derivedDataPath /tmp/reason-network-build build
./Tests/run-checks.sh
./Tools/package-release.sh /tmp/reason-network-release
```

The packaging script checks both architectures and signatures and produces a development DMG with a SHA-256 checksum. Use the release download above for the notarized app. [Backend build and recovery guide (Chinese)](Engine/README.md)
