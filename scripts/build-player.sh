#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
if [[ "${1:-}" != "--host-only" || ! -f build/mpv/libmpv.2.dylib ]]; then scripts/build-mpv.sh; fi
mkdir -p build/IIVE-Player.app/Contents/MacOS
clang -fobjc-arc -fmodules -Wno-deprecated-declarations -I .research/mpv-native/include \
 native/Player/main.m native/Player/VideoView.m build/mpv/libmpv.2.dylib \
 -Wl,-rpath,"$PWD/build/mpv" -framework AppKit -framework OpenGL \
 -o build/IIVE-Player.app/Contents/MacOS/IIVE-Player
cp native/Player/Info.plist build/IIVE-Player.app/Contents/Info.plist
printf 'Built experimental player: %s/build/IIVE-Player.app\n' "$PWD"
