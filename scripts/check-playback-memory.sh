#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/checks
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/checks/swift-modules \
 PlayerSystem/PlaybackMemory.swift tests/PlaybackMemorySmoke.swift -o build/checks/playback-memory-smoke
build/checks/playback-memory-smoke
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/checks/swift-modules \
 PlayerSystem/NetworkMedia.swift PlayerSystem/RemotePlaybackMemory.swift tests/RemotePlaybackMemorySmoke.swift -o build/checks/remote-playback-memory-smoke
build/checks/remote-playback-memory-smoke
