#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" || ! -d "${DEVELOPER_DIR}" ]]; then
  if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ -d "/Library/Developer/CommandLineTools" ]]; then
    export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
  fi
fi
configuration="${1:-Debug}"
case "$configuration" in Debug|Release) ;; *) echo "Use Debug or Release" >&2; exit 2;; esac
mkdir -p build
xcrun xcodebuild -project LumaPlayer.xcodeproj -scheme 'Luma Player' \
 -configuration "$configuration" -derivedDataPath "$PWD/build/Xcode" \
 -destination 'platform=macOS,arch=arm64' build

python3 scripts/package-player.py "$configuration"
