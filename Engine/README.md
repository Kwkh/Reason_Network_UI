# 逐会话退出

「我的会话」通过本机 Unix socket 管理后台登记。补丁基于 Reason Network 0.12.12，只暂停所选会话。退出状态写入现有数据库，会在守护进程重启后恢复。

## 构建

从本仓库根目录运行。使用能满足上游 `Cargo.lock` 依赖的 Rust 工具链。

```sh
patch_file="$PWD/Engine/session-participation.patch"
engine_source="$(mktemp -d /tmp/reason-network-engine.XXXXXX)"
git clone --no-checkout https://github.com/reason-machines/reason-network.git "$engine_source"
git -C "$engine_source" checkout --detach 27252c24cf073bab5d0ede7ba56611a2750e1d3a
git -C "$engine_source" apply --check "$patch_file"
git -C "$engine_source" apply "$patch_file"
cargo build --locked --release --manifest-path "$engine_source/Cargo.toml"
cargo test --locked --release --manifest-path "$engine_source/Cargo.toml" \
  paused_session_rejects_hooks_and_mcp_until_explicitly_resumed
```

## 配置 macOS 后台

先完成官方 Reason Network 的安装和登录。在原终端中执行以下命令，将构建好的后台放在独立路径。维护期间，正在使用的 Reason Network 连接会短暂重连。

```sh
engine_bin="$HOME/.reason/bin/reason-network-participation"
launch_plist="$HOME/Library/LaunchAgents/com.reasonmachines.network.plist"
launch_domain="gui/$(id -u)"
plist_backup="$(mktemp "$launch_plist.backup.XXXXXX")"
cp -p "$launch_plist" "$plist_backup"
install -m 755 "$engine_source/target/release/reason-network" "$engine_bin"
codesign --verify --strict "$engine_bin"
```

在 `$launch_plist` 中，把 `ProgramArguments` 的第一项改为 `$engine_bin` 对应的绝对路径，保留后面的 `daemon` 和 `--service`。在 `EnvironmentVariables` 中设置 `REASON_NETWORK_LOCAL_PARTICIPATION` 为字符串 `1`，使运行中的扩展后台保留到下一次手动更新。用以下命令重载，重新打开 App 后在「我的会话」确认「退出」可用。

```sh
plutil -lint "$launch_plist" &&
  launchctl bootout "$launch_domain/com.reasonmachines.network" &&
  launchctl bootstrap "$launch_domain" "$launch_plist"
```

需要恢复官方后台时，先用 `launchctl bootout "$launch_domain/com.reasonmachines.network"` 卸载当前服务，再执行 `cp -p "$plist_backup" "$launch_plist"` 和 `launchctl bootstrap "$launch_domain" "$launch_plist"`。
