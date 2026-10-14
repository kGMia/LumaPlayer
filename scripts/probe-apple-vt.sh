#!/bin/bash
# Small API evaluation only. --process performs six synthetic midpoint calls per size.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
mkdir -p build
xcrun clang -fobjc-arc native/Experiments/apple-vt-probe.m \
 -framework Foundation -framework VideoToolbox -framework CoreMedia \
 -framework CoreVideo -framework Metal -framework MetalFX -o build/apple-vt-probe
exec build/apple-vt-probe "$@"
