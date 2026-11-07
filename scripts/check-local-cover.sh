#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/checks/local-cover
/opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=black:s=320x180:r=24:d=4' -f lavfi -i 'color=c=blue:s=320x180:r=24:d=8' -filter_complex '[0:v][1:v]concat=n=2:v=1:a=0' -c:v libx264 -preset ultrafast -g 24 build/checks/local-cover/opening.mkv
/opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=black:s=320x180:r=24:d=2' -c:v libx264 -preset ultrafast -g 24 build/checks/local-cover/black.mkv
xcrun clang -fobjc-arc -I/opt/homebrew/include -Inative/Player/Modern -L/opt/homebrew/lib -lavformat -lavcodec -lavutil -lswscale -framework Foundation -framework CoreGraphics -framework ImageIO native/Player/Modern/RemoteMediaProbe.m tests/LocalCoverSmoke.m -o build/checks/local-cover/check
build/checks/local-cover/check "$PWD/build/checks/local-cover/opening.mkv" "$PWD/build/checks/local-cover/black.mkv"
