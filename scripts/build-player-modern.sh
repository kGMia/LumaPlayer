#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build
xcrun xcodebuild -project IIVEPlayer.xcodeproj -scheme 'IIVE Player' \
 -configuration "${1:-Debug}" -derivedDataPath "$PWD/build/Xcode" \
 -destination 'platform=macOS,arch=arm64' build
