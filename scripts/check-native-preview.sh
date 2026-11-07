#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/checks .cache/seek-smoke-modules
test -f build/checks/preview-regression/chapters.mkv || bash scripts/check-timeline-preview.sh
xcrun clang -fobjc-arc -I/opt/homebrew/include -c native/Player/Modern/LocalVideoPreview.m -o build/checks/local-video-preview.o
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path .cache/seek-smoke-modules \
 -import-objc-header native/Player/Modern/LocalVideoPreview.h \
 PlayerSystem/FFmpegPreviewDecoder.swift tests/NativePreviewSmoke.swift build/checks/local-video-preview.o \
 -L/opt/homebrew/lib -lavformat -lavcodec -lavutil -lswscale \
 -o build/checks/native-preview-smoke
build/checks/native-preview-smoke build/checks/preview-regression/chapters.mkv
