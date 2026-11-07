#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
mkdir -p build/edr-prototype
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Werror -Wno-deprecated-declarations -mmacosx-version-min=27.0 \
  tests/EDRSurfaceSmoke.m -framework Foundation -framework Metal -framework CoreVideo -framework OpenGL -framework IOSurface \
  -o build/edr-prototype/surface-smoke
if [[ "${1:-}" != "--build-only" ]]; then build/edr-prototype/surface-smoke; fi
