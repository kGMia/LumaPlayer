#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/checks
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=red:s=320x180:r=24:d=1' \
 -c:v libx264 -pix_fmt yuv420p build/checks/asset-image.mp4
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path build/checks/swift-modules \
 PlayerSystem/FFmpegPreviewDecoder.swift tests/AssetImageReaderSmoke.swift -o build/checks/asset-image-smoke
build/checks/asset-image-smoke "$PWD/build/checks/asset-image.mp4"
