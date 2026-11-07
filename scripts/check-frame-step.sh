#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/checks
/opt/homebrew/bin/ffmpeg -v error -y -f lavfi -i testsrc2=size=160x90:rate=24 \
  -t 2 -c:v libx264 -g 48 -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 \
  -colorspace bt709 -color_range tv build/checks/frame-step.mp4
xcrun clang -I.research/mpv-native/include tests/frame_step_smoke.c build/mpv/libmpv.2.dylib \
  -Wl,-rpath,"$PWD/build/mpv" -o build/checks/frame-step-smoke
build/checks/frame-step-smoke "$PWD/build/checks/frame-step.mp4" "$@"
