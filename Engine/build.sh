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
export MACOSX_DEPLOYMENT_TARGET=14.0
rustup target add aarch64-apple-darwin x86_64-apple-darwin
cargo test --locked --release paused_session_rejects_hooks_and_mcp_until_explicitly_resumed
for target in aarch64-apple-darwin x86_64-apple-darwin; do
    cargo build --locked --release --target "$target"
done
lipo -create target/aarch64-apple-darwin/release/reason-network target/x86_64-apple-darwin/release/reason-network -output "$work/backend"
codesign --force -s - "$work/backend"
codesign --verify --strict --all-architectures "$work/backend"
install -m 755 "$work/backend" "$engine_dir/Bin/reason-network-backend"
