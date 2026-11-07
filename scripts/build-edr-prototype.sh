#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/edr-prototype .cache/clang
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Werror -Wno-deprecated-declarations \
  -mmacosx-version-min=27.0 -dynamiclib native/Player/Experimental/IIVEEDRBridge.m \
  -framework Foundation -framework QuartzCore -framework Metal -framework CoreVideo \
  -framework IOSurface -framework OpenGL -framework CoreGraphics \
  -o build/edr-prototype/libIIVEEDRPrototype.dylib
