#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/checks
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path build/checks/swift-modules \
 PlayerSystem/QueueMetadataValue.swift PlayerSystem/MediaReadScheduling.swift PlayerSystem/RemoteMetadataCache.swift \
 tests/RemoteMetadataCacheSmoke.swift -o build/checks/remote-metadata-smoke
build/checks/remote-metadata-smoke
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path build/checks/swift-modules \
 PlayerSystem/NetworkMedia.swift tests/NetworkMediaSmoke.swift -o build/checks/network-media-policy-smoke
build/checks/network-media-policy-smoke
