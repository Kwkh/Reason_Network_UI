#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
output_dir="${1:-$project_dir/build/release}"
mkdir -p "$output_dir"
output_dir="${output_dir:A}"
work_dir="$(mktemp -d /tmp/reason-ui-release.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
xcodebuild -project "$project_dir/Reason Network.xcodeproj" -scheme 'Reason Network' \
 -configuration Release -derivedDataPath "$work_dir/DerivedData" \
 ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build > "$output_dir/build.log" 2>&1
app="$work_dir/DerivedData/Build/Products/Release/Reason Network.app"
/usr/bin/lipo "$app/Contents/MacOS/Reason Network" -verify_arch arm64 x86_64
/usr/bin/lipo "$app/Contents/MacOS/reason-network-backend" -verify_arch arm64 x86_64
/usr/bin/codesign --verify --strict --all-architectures "$app/Contents/MacOS/reason-network-backend"
/usr/bin/codesign --verify --deep --strict "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")"
staging="$work_dir/Disk"
mkdir -p "$staging"
/usr/bin/ditto "$app" "$staging/Reason Network.app"
ln -s /Applications "$staging/Applications"
cat > "$staging/Read Me.txt" <<'INFO'
Reason Network · macOS 14+

将 Reason Network.app 拖入 Applications 后打开。
首次启动会检查环境，可一键安装内置兼容后台、配置代理接入和通过邀请加入 Network。
配置会添加官方 MCP / hooks 和登录后台服务。邀请方需要在线。
已有配置会继续沿用；本工具不迁移其他机器的消息历史。

本预览版使用本地临时签名，尚未完成 Apple Developer ID 签名和公证。
从 GitHub 下载后，macOS 可能阻止首次打开。请先尝试打开 App，再到
系统设置 → 隐私与安全性查看“仍要打开”。请仅在确认下载来自项目官方仓库后允许。
如系统不提供允许入口，可使用仓库源码在 Xcode 中构建运行。
无需关闭系统安全保护。本包不会自动解除隔离或修改 Gatekeeper 设置。

源码和发布：https://github.com/Kwkh/Reason_Network_UI
后台来源：https://github.com/reason-machines/reason-network
INFO
artifact="Reason-Network-$version-macOS-universal.dmg"
hdiutil create -volname 'Reason Network' -srcfolder "$staging" -ov -format UDZO "$output_dir/$artifact"
(cd "$output_dir" && shasum -a 256 "$artifact" > "$artifact.sha256")
printf 'Packaged version %s (build %s): %s\n' "$version" "$build_number" "$output_dir/$artifact"
