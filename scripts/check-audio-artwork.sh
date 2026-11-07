#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
scratch=$(mktemp -d /tmp/iive-artwork-check.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library -O -module-cache-path "$scratch/modules" \
 PlayerSystem/MediaReadScheduling.swift PlayerSystem/AudioArtwork.swift PlayerSystem/FFmpegPreviewDecoder.swift \
 tests/AudioArtworkDecodeSmoke.swift -o "$scratch/check"
"$scratch/check" "${1:-$PWD/build/audio-smoke}"
