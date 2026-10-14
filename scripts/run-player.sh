#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -x build/IIVE-Player.app/Contents/MacOS/IIVE-Player ]]; then
  echo 'Build first: scripts/build-player.sh' >&2; exit 1
fi
if [[ $# -eq 0 ]]; then exec build/IIVE-Player.app/Contents/MacOS/IIVE-Player; fi
input="$1"; fps="${2:-48}"; tier="${3:-fast}"
if [[ ! -f "$input" ]]; then echo 'Input video does not exist.' >&2; exit 2; fi
if [[ "$fps" != 48 && "$fps" != 60 ]]; then echo 'FPS must be 48 or 60.' >&2; exit 2; fi
case "$tier" in fast|balanced|hq) ;; *) echo 'Tier must be fast, balanced or hq.' >&2; exit 2;; esac
exec build/IIVE-Player.app/Contents/MacOS/IIVE-Player --input "$input" --fps "$fps" --tier "$tier"
