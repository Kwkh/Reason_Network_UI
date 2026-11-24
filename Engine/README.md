# macOS 逐会话退出后台

移植自 Samson 的 Reason Network Chat 分支 a01bf50。基线为官方 0.12.17（5872711）。
新机打开「环境配置」，点击「安装并配置」。App 内置双架构后台，普通用户无需开发工具。已有同版本官方 CLI 的机器可点击「配置后台与会话」。激活时会短暂重启当前用户的 Reason 服务。安装器保留已有 CLI，备份原 LaunchAgent，再探测新服务的逐会话管理能力。失败时恢复原配置。

状态面板的接收模式选择器只作用于当前本机 Codex 会话。后台按线程保存偏好，实时目录报告实际模式。手动接收仅在主动检查收件箱时投递，回合接收需已建立会话 hooks，即时推送需要支持 `queue --resume` 的 Codex CLI。空闲会话收到要求唤醒的消息时，后台向指定线程排队并请求恢复。若 Codex 已接收消息但恢复失败，可在诊断中查看提示，打开该线程即可继续。旧版兼容后台可从环境配置更新。

兼容后台会核对本机原生 Codex 线程。已归档、缺失或暂时无法核实的线程会从在线目录移除，并停止接受新投递和唤醒。恢复同一线程后，后台会按实际连接状态重新公布。App 保留已缓存的 Network 聊天和本次打开期间的草稿。

在侧栏设置的「概览」中点击网络名称，可以切换、新建或通过完整邀请链接加入 Network。进入目标 Network 后，在「我的会话」中选择要接入的 Codex 对话。同一对话可以在几个 Network 中接入。切换界面时，各 Network 的后台继续运行。

第一个工作区沿用原数据目录。额外的工作区在 `~/.reason/workspaces/` 下各有自己的数据库、收件箱、聊天缓存和登录服务。Codex 的 MCP 与 hooks 继续连接默认后台。它按消息携带的 Network ID 投递回复，跨网重复的联系人地址需要指定 Network。一个 Codex 线程仍共享自己的模型上下文。

维护者可使用 `Tests/run-checks.sh --workspaces` 运行隔离测试。测试会在临时主目录创建两个 Network，并在当前用户的 launchd 域启动及清理一个单独命名的测试服务。

维护者可运行 `Engine/build.sh` 从固定提交重新生成 `Engine/Bin/reason-network-backend`。这一步需要 Git、Rust（rustup）和 Xcode 命令行工具。自定义后台需要手动跟进上游更新。

在 App 的状态菜单点击「退出当前会话」可暂停该会话，之后可在「我的会话」重新加入。暂停状态保存在现有引擎数据库，服务重启后仍然有效。

恢复原服务时，使用本次激活前保存在 `~/Library/Application Support/Reason Network UI/Backend/launch-agent-*.plist` 的备份，将下面的 BACKUP 替换为该路径。

```sh
launchctl bootout "gui/$(id -u)/com.reasonmachines.network"
cp "BACKUP" "$HOME/Library/LaunchAgents/com.reasonmachines.network.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.reasonmachines.network.plist"
```
