#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/live-text-smoke
xcrun swiftc -swift-version 6 -parse-as-library \
  PlayerSystem/LiveTextWindow.swift tests/LiveTextSessionSmoke.swift \
  -o build/live-text-smoke/check
build/live-text-smoke/check
