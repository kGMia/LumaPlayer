#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/file-dialog-smoke
xcrun swiftc -swift-version 6 -parse-as-library \
  PlayerSystem/FileDialogs.swift tests/FileDialogsSmoke.swift \
  -o build/file-dialog-smoke/check
build/file-dialog-smoke/check
