# macOS 逐会话退出后台

移植自 Samson 的 Reason Network Chat 分支 a01bf50。基线为官方 0.12.17（5872711）。
新机打开「环境配置」，点击「安装并配置」。App 内置双架构后台，普通用户无需开发工具。已有同版本官方 CLI 的机器可点击「配置后台与会话」。激活时会短暂重启当前用户的 Reason 服务。安装器保留已有 CLI，备份原 LaunchAgent，再探测新服务的逐会话管理能力。失败时恢复原配置。

状态面板的接收模式选择器只作用于当前本机 Codex 会话。后台按线程保存偏好，实时目录报告实际模式。手动接收仅在主动检查收件箱时投递，回合接收需已建立会话 hooks，即时推送需要支持 `queue --resume` 的 Codex CLI。空闲会话收到要求唤醒的消息时，后台向指定线程排队并请求恢复。若 Codex 已接收消息但恢复失败，可在诊断中查看提示，打开该线程即可继续。旧版兼容后台可从环境配置更新。

维护者可运行 `Engine/build.sh` 从固定提交重新生成 `Engine/Bin/reason-network-backend`。这一步需要 Git、Rust（rustup）和 Xcode 命令行工具。自定义后台需要手动跟进上游更新。

在 App 的状态菜单点击「退出当前会话」可暂停该会话，之后可在「我的会话」重新加入。暂停状态保存在现有引擎数据库，服务重启后仍然有效。

恢复原服务时，使用本次激活前保存在 `~/Library/Application Support/Reason Network UI/Backend/launch-agent-*.plist` 的备份，将下面的 BACKUP 替换为该路径。

```sh
launchctl bootout "gui/$(id -u)/com.reasonmachines.network"
cp "BACKUP" "$HOME/Library/LaunchAgents/com.reasonmachines.network.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.reasonmachines.network.plist"
```
