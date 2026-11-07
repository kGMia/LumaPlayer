#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/geometry-smoke
xcrun clang -Wall -Wextra -Werror tests/VideoCropSmoke.c -o build/geometry-smoke/crop
build/geometry-smoke/crop
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path build/geometry-smoke/cache \
  PlayerSystem/PlaybackGeometry.swift tests/PlaybackGeometrySmoke.swift -o build/geometry-smoke/state
build/geometry-smoke/state
python3 - <<'PY'
import wave
with wave.open('build/geometry-smoke/silence.wav', 'wb') as f:
    f.setnchannels(1); f.setsampwidth(2); f.setframerate(16000)
    f.writeframes(bytes(16000 * 2 * 2))
PY
xcrun clang -I.research/mpv-native/include tests/PlaybackGeometryMPVSmoke.c build/mpv/libmpv.2.dylib \
  -Wl,-rpath,"$PWD/build/mpv" -o build/geometry-smoke/mpv
build/geometry-smoke/mpv "$PWD/build/geometry-smoke/silence.wav"
