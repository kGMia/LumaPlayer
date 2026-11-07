#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/checks
python3 - <<'PY'
import wave
with wave.open('build/checks/recovery-fixture.wav', 'wb') as f:
    f.setnchannels(1); f.setsampwidth(2); f.setframerate(16000)
    f.writeframes(bytes(64000))
PY
xcrun clang -I.research/mpv-native/include tests/RemoteRecoveryHookSmoke.c build/mpv/libmpv.2.dylib \
 -Wl,-rpath,"$PWD/build/mpv" -o build/checks/remote-recovery-hook-smoke
build/checks/remote-recovery-hook-smoke "$PWD/build/checks/recovery-fixture.wav"
build/checks/remote-recovery-hook-smoke "$PWD/build/checks/recovery-fixture.wav" --terminal
xcrun swiftc -swift-version 5 -module-cache-path build/checks/swift-modules \
 PlayerSystem/RIFEPerformancePolicy.swift tests/RIFEPerformancePolicySmoke.swift -o build/checks/rife-policy-smoke
build/checks/rife-policy-smoke
