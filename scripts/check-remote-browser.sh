#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/checks
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path build/checks/swift-modules \
 PlayerSystem/NetworkMedia.swift PlayerSystem/OneDriveGraph.swift PlayerSystem/RemoteBrowserState.swift \
 tests/RemoteBrowserStateSmoke.swift -o build/checks/remote-browser-smoke
build/checks/remote-browser-smoke
