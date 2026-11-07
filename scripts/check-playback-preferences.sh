#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/preferences-smoke
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path build/preferences-smoke/cache \
  PlayerSystem/PlaybackPreferences.swift PlayerSystem/PlaybackMemory.swift tests/PlaybackPreferencesSmoke.swift \
  -o build/preferences-smoke/check
build/preferences-smoke/check
