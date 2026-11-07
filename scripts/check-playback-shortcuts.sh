#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/shortcut-smoke
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path build/shortcut-smoke/cache \
  PlayerSystem/PlaybackShortcutPolicy.swift tests/PlaybackShortcutSmoke.swift -o build/shortcut-smoke/check
build/shortcut-smoke/check
