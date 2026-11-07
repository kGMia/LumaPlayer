#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
scripts/build-apple.sh
xcrun clang -fobjc-arc -fmodules -arch arm64 -mmacosx-version-min=27.0 \
 tests/NV12NormalizerSmoke.m -I native/AppleBackend -L build/apple -lIIVEApple \
 -Wl,-rpath,"$PWD/build/apple" -framework Foundation -framework CoreVideo \
 -o build/apple/nv12-normalizer-smoke
if [[ "${1:-}" != "--build-only" ]]; then build/apple/nv12-normalizer-smoke; fi
