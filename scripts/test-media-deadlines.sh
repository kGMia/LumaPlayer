#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
tmpdir=$(mktemp -d /tmp/iive-media-deadlines.XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$tmpdir/modules" \
 PlayerSystem/MediaReadScheduling.swift tests/MediaDeadlineSmoke.swift -o "$tmpdir/smoke"
"$tmpdir/smoke"
