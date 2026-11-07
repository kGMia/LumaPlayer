#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/checks
xcrun swiftc -module-cache-path "$PWD/.cache/clang" \
  PlayerSystem/PlayerTimeline.swift tests/TransportFeedbackSmoke.swift \
  -o build/checks/transport-feedback-smoke
build/checks/transport-feedback-smoke
