#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"
if [[ -z "${DEVELOPER_DIR:-}" || ! -d "${DEVELOPER_DIR}" ]]; then
  if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ -d "/Library/Developer/CommandLineTools" ]]; then
    export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
  fi
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
# Dependencies: meson ninja pkgconf ffmpeg libass libplacebo lcms2 (Homebrew core).
src="$PWD/.research/mpv-native"
if [[ ! -d "$src/.git" ]]; then
  git clone https://github.com/mpv-player/mpv.git "$src"
  git -C "$src" checkout --detach 88eb9f2e73945d8bc9c133a2f67babaa9af34680
fi
scripts/build-native.sh
scripts/build-apple.sh
python3 scripts/prepare-mpv.py "$src"
meson setup --reconfigure build/mpv "$src" --buildtype=release \
  -Dauto_features=disabled -Dgpl=true -Dlibmpv=true -Dcplayer=true \
  -Dgl=enabled -Dplain-gl=enabled -Dcoreaudio=enabled -Dswift-build=disabled \
  -Dlcms2=enabled -Dcocoa=disabled -Dgl-cocoa=disabled -Dvideotoolbox-gl=enabled
meson compile -C build/mpv
clang -Wno-deprecated-declarations -I "$src/include" scripts/render-smoke.c \
  build/mpv/libmpv.2.dylib -Wl,-rpath,"$PWD/build/mpv" -framework OpenGL -o build/render-smoke
echo "Built $PWD/build/mpv/mpv (separate player, not installed into IINA)"
