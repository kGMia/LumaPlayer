#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
bash scripts/check-remote-browser.sh
xcrun clang -I.research/mpv-native/include tests/RemoteBatchQueueSmoke.c build/mpv/libmpv.2.dylib \
 -Wl,-rpath,"$PWD/build/mpv" -o build/checks/remote-batch-queue-smoke
build/checks/remote-batch-queue-smoke
