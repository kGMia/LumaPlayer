#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
scratch=$(mktemp -d /tmp/iive-queue-check.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
python3 - "$scratch" <<'PY'
from pathlib import Path
import sys, wave
out = Path(sys.argv[1])
for name, seconds in [('track.wav', 1), ('replacement.wav', 2)]:
    with wave.open(str(out / name), 'wb') as media:
        media.setnchannels(1); media.setsampwidth(2); media.setframerate(16000)
        media.writeframes(b'\0\0' * 16000 * seconds)
PY
/opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=320x180:rate=12 -t 2 -c:v ffv1 "$scratch/clip.mkv"
xcrun clang -fobjc-arc -I/opt/homebrew/include -c native/Player/Modern/RemoteMediaProbe.m -o "$scratch/probe.o"
xcrun swiftc -import-objc-header native/Player/Modern/RemoteMediaProbe.h -swift-version 6 -D FOLDER_MEDIA_TEST -parse-as-library -O -module-cache-path "$scratch/modules" \
 PlayerSystem/QueueMetadataValue.swift PlayerSystem/QueueMetadata.swift PlayerSystem/MediaReadScheduling.swift PlayerSystem/FolderQueue.swift PlayerSystem/AudioArtwork.swift \
 PlayerSystem/FFmpegPreviewDecoder.swift tests/QueueMetadataSmoke.swift "$scratch/probe.o" -L/opt/homebrew/lib -lavformat -lavcodec -lavutil -lswscale -o "$scratch/check"
"$scratch/check" "$scratch"
