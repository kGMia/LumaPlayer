#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Generated media only; no GUI/player launch. Checks the actual Swift decoder.
set -euo pipefail
cd "$(dirname "$0")/.."
FFMPEG_PREVIEW_BIN="$(command -v ffmpeg)"
fixture_dir=build/checks/preview-regression
mkdir -p "$fixture_dir" .cache/seek-smoke-modules
cat > "$fixture_dir/chapters.ffmeta" <<'META'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=2000
title=Red
[CHAPTER]
TIMEBASE=1/1000
START=2000
END=4000
title=Green
[CHAPTER]
TIMEBASE=1/1000
START=4000
END=6000
title=Blue
META
"$FFMPEG_PREVIEW_BIN" -hide_banner -loglevel error -y \
  -f lavfi -i 'color=red:s=320x180:r=24:d=2' \
  -f lavfi -i 'color=green:s=320x180:r=24:d=2' \
  -f lavfi -i 'color=blue:s=320x180:r=24:d=2' \
  -f ffmetadata -i "$fixture_dir/chapters.ffmeta" \
  -filter_complex '[0:v][1:v][2:v]concat=n=3:v=1:a=0,drawbox=x=5:y=9:w=37:h=23:color=white:t=fill,drawbox=x=250:y=130:w=51:h=31:color=black:t=fill[v]' \
  -map '[v]' -map_metadata 3 -map_chapters 3 -c:v libx264 -preset ultrafast -g 48 \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 "$fixture_dir/chapters.mkv"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path .cache/seek-smoke-modules \
  PlayerSystem/FFmpegPreviewDecoder.swift tests/TimelinePreviewDecodeSmoke.swift \
  -o build/checks/timeline-preview-decode
build/checks/timeline-preview-decode "$fixture_dir/chapters.mkv"
