#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/checks
xcrun clang -fobjc-arc -I/opt/homebrew/include -Inative/Player/Modern -L/opt/homebrew/lib \
  -lavformat -lavcodec -lavutil -lswscale -framework Foundation -framework CoreGraphics -framework ImageIO \
  native/Player/Modern/RemoteMediaProbe.m tests/RemoteMediaProbeSmoke.m -o build/checks/remote-probe-smoke
xcrun clang -I.research/mpv-native/include tests/RemoteQueueHookSmoke.c build/mpv/libmpv.2.dylib \
  -Wl,-rpath,"$PWD/build/mpv" -o build/checks/remote-queue-hook-smoke
python3 tests/remote_queue_smoke.py
