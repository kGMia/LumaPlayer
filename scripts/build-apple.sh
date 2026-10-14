#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
mkdir -p build/apple
xcrun clang -fobjc-arc -fmodules -mmacosx-version-min=27.0 -arch arm64 -dynamiclib \
 native/AppleBackend/AppleBackend.m -framework VideoToolbox -framework CoreMedia \
 -framework CoreVideo -framework Foundation -install_name @rpath/libIIVEApple.dylib \
 -o build/apple/libIIVEApple.dylib
