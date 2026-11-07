#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" || ! -d "${DEVELOPER_DIR}" ]]; then
  if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ -d "/Library/Developer/CommandLineTools" ]]; then
    export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
  fi
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/clang"
xcrun swift build --package-path native/RIFEBackend -c release --disable-sandbox --cache-path "$PWD/.cache/swift"
python3 scripts/export-fsrcnnx.py
xcrun swift build --package-path native/FSRCNNXMetal -c release --disable-sandbox --cache-path "$PWD/.cache/swift"
