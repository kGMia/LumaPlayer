#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/clang"
swift build --package-path native/RIFEBackend -c release --disable-sandbox --cache-path "$PWD/.cache/swift"
python3 scripts/export-fsrcnnx.py
swift build --package-path native/FSRCNNXMetal -c release --disable-sandbox --cache-path "$PWD/.cache/swift"
