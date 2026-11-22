#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
checks_dir="$(mktemp -d /tmp/reason-native-checks.XXXXXX)"
trap 'rm -rf "$checks_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$checks_dir/cache" \
 "$project_dir/Sources/SetupService.swift" "$project_dir/Sources/Models.swift" "$project_dir/Sources/SQLiteStore.swift" \
 "$project_dir/Sources/TranscriptMirror.swift" "$project_dir/Sources/ReasonService.swift" \
 "$project_dir/Tests/CoreChecks.swift" -lsqlite3 -o "$checks_dir/CoreChecks"
"$checks_dir/CoreChecks"
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$checks_dir/cache" \
 "$project_dir/Sources/Models.swift" "$project_dir/Sources/SetupService.swift" \
 "$project_dir/Sources/SetupModel.swift" "$project_dir/Tests/SetupChecks.swift" -o "$checks_dir/SetupChecks"
"$checks_dir/SetupChecks"
