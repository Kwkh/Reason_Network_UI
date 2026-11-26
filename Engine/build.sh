#!/bin/sh
set -eu
engine_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone --quiet --branch v0.12.17 --depth 1 https://github.com/reason-machines/reason-network.git "$work/src"
cd "$work/src"
test "$(git rev-parse HEAD)" = 5872711927788b0d43a8a940ea45f993bc2926bc
git apply --check "$engine_dir/session-participation.patch"
git apply "$engine_dir/session-participation.patch"
git apply "$engine_dir/receive-mode.patch"
git apply "$engine_dir/codex-wake.patch"
git apply "$engine_dir/connection-recovery.patch"
git apply "$engine_dir/native-thread-guard.patch"
git apply "$engine_dir/network-workspaces.patch"
git apply "$engine_dir/codex-resume-server.patch"
git apply "$engine_dir/founder-admin.patch"
git apply "$engine_dir/departure-notices.patch"
git apply "$engine_dir/multi-agent-workspaces.patch"
git apply "$engine_dir/native-agent-wake.patch"
git apply "$engine_dir/app-integrations.patch"
git apply "$engine_dir/dsh-session-identity.patch"
git apply "$engine_dir/native-titles.patch"
git apply "$engine_dir/harness-presence.patch"
git apply "$engine_dir/agent-session-join.patch"
git apply "$engine_dir/session-join-diagnostics.patch"
git apply "$engine_dir/agent-join-setup.patch"
git apply "$engine_dir/dsh-presence.patch"
git apply "$engine_dir/compact-replies.patch"
git apply "$engine_dir/default-native-push.patch"
git apply "$engine_dir/native-activity.patch"
export MACOSX_DEPLOYMENT_TARGET=14.0
rustup target add aarch64-apple-darwin x86_64-apple-darwin
cargo test --locked --release native_rename_after_long_records_and_compression
cargo test --locked --release founder_management_is_scoped_and_terminal
cargo test --locked --release paused_session_rejects_hooks_and_mcp_until_explicitly_resumed
cargo test --locked --release dropping_an_unpublished_connection_closes_its_peer
for target in aarch64-apple-darwin x86_64-apple-darwin; do
    cargo build --locked --release --target "$target"
done
lipo -create target/aarch64-apple-darwin/release/reason-network target/x86_64-apple-darwin/release/reason-network -output "$work/backend"
codesign --force -s - "$work/backend"
codesign --verify --strict --all-architectures "$work/backend"
python3 "$engine_dir/../Tests/receive-mode-checks.py" "$work/backend"
python3 "$engine_dir/../Tests/workspace-checks.py" "$work/backend"
python3 "$engine_dir/../Tests/native-wake-checks.py" "$work/backend"
install -m 755 "$work/backend" "$engine_dir/Bin/reason-network-backend"
