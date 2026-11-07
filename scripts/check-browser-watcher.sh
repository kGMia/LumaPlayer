#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/checks/browser-watcher
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path build/checks/browser-watcher/cache \
 PlayerSystem/BrowserDirectoryWatcher.swift tests/BrowserDirectoryWatcherSmoke.swift \
 -o build/checks/browser-watcher/check
build/checks/browser-watcher/check
