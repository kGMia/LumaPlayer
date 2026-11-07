#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/checks benchmarks/results
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/checks/swift-modules \
 PlayerSystem/NetworkMedia.swift tests/NetworkMediaSmoke.swift -o build/checks/network-media-smoke
if [[ "${1:-}" == "--integration" ]]; then
    python3 tests/network_stream_smoke.py
else
    build/checks/network-media-smoke
fi
