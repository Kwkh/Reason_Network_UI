# Reason Network Windows 开发与联调

Windows 工作在本仓库的 `windows` 分支进行。基线为已发布的 [macOS v1.2.4](https://github.com/Kwkh/Reason_Network_UI/releases/tag/v1.2.4)，源码提交 `f7d1baab926ded5006ae2f471077243e841014e1`。Mac 端使用这份公证发行包和配套后台参与验收。Windows 分支自行维护客户端、后台适配、测试与安装包，PR 的目标分支选 `windows`。

## 在 Windows 上开始

```powershell
git clone --branch windows https://github.com/Kwkh/Reason_Network_UI.git
Set-Location Reason_Network_UI
git switch -c windows-first-milestone
```

首轮以 Windows 11 x64 为验证环境。准备 Git、Visual Studio 的 WinUI 与 C++ MSVC 构建工具、Windows SDK、.NET SDK 和 Rust MSVC 工具链。仓库目前提供 macOS 源码和后台补丁；第一个 Windows PR 应带上可重复执行的构建命令与 Windows CI。界面可用 C# / WinUI 3，按现有侧栏、工作区切换、聊天和输入行为实现。

| 路径 | 用途 |
| --- | --- |
| [Engine/build.sh](Engine/build.sh) | 后台基于上游 `v0.12.17`（`5872711927788b0d43a8a940ea45f993bc2926bc`）。沿用脚本里的补丁顺序，为 Windows 编写独立构建入口。该脚本及 `Engine/Bin/reason-network-backend` 对应 macOS。 |
| [Sources/ReasonService.swift](Sources/ReasonService.swift)、[Sources/NetworkWorkspaces.swift](Sources/NetworkWorkspaces.swift) | 参考消息历史、会话身份、Network 选择和后台调用。引擎数据库由后台管理，客户端读取历史时使用只读连接。 |
| [Sources/ContentView.swift](Sources/ContentView.swift)、[Sources/NetworkModel.swift](Sources/NetworkModel.swift) | 参考侧栏、会话状态、输入法、滚动、草稿和消息回执。 |
| [Tests/workspace-checks.py](Tests/workspace-checks.py)、[Tests/receive-mode-checks.py](Tests/receive-mode-checks.py)、[Tests/native-wake-checks.py](Tests/native-wake-checks.py) | 参考多工作区、Push/Pull 和唤醒用例。Windows 用例需适配命名管道和平台进程管理。 |

## 实现顺序

1. **后台与基本收发。** 沿用 v1.2.4 的网络协议、身份和回执语义。借助 Rust 上游已有的 Windows 命名管道，把目前走 Unix 套接字的工作区分发移植过去。接着打通创建或加入 Network、会话登记、目录刷新、消息和附件收发。
2. **原对话与客户端。** 先验证 Windows Codex 能根据原线程身份实际接收 Push，再对齐 Claude Code 和 dsh 的原对话唤醒、退出后离线和重启恢复。Gemini CLI 按 Mac 1.2.4 的已支持能力对齐。后台核实通道后再向界面报告 Push 已生效。短回信地址必须在接收设备上解析为原 Network、发送会话和原消息。
3. **安装与桌面体验。** 验证干净 Windows 用户环境的首次配置、升级、登录后台和卸载。核对中文输入法合成、长文本、侧栏缩放时保留阅读位置、每条会话的草稿以及通知。CI 验证构建与自动用例，Windows 桌面验证安装和原工具的实际行为。

## Mac ↔ Windows 联调

Mac 安装正式版 v1.2.4，Windows 使用注明提交号的测试构建。双方用独立测试身份建立临时 Network。验证清单如下。

| 场景 | 通过条件 |
| --- | --- |
| 双向收发 | 两端通过邀请加入，相互可见。各向对方发一条可区分的消息并回信，正文、会话地址和回执正确。 |
| Push 与 Pull | Mac 向 Windows 的空闲原 Codex 线程发 Push，确认正文出现在同一线程，再用短回信地址回复；Mac 将回复关联到正确的原消息。Windows → Mac 也跑一遍。Pull 消息在原会话主动接收时可读。 |
| 多 Network | 同一原会话加入两个测试 Network。两边发送相同正文，逐一回复；核对路由、消息历史、接收模式和断开状态各自独立。 |
| 生命周期和重启 | 关闭原工具会话后目录显示离线。重新打开或重启后台后核对恢复的会话地址、待收消息和接收模式。手动断开的会话保持断开。用重启前显示的短回信地址回复一次。 |
| 安装、失败和重试 | 在干净 Windows 环境验证安装和首次接入。测试收件方离线与回复重试，核对待投递消息和回执，确认没有重复发送。 |

记录两端构建号、Windows 版本及架构、原工具版本、复现步骤与观察结果。首轮以 **Mac 发信 → Windows 唤醒原 Codex 对话 → 短地址回信 → Mac 显示「已回复」** 为验收线。

## 发布

Windows 预览版可在同一仓库的 Releases 使用 `windows-v…` 标签并标为预发布。两端通过联调后，同一条正式 Release 可同时提供公证的 macOS DMG 和 Windows 安装包。附件名标明平台和架构，发布说明列明两个包各自的源码标签或提交。
