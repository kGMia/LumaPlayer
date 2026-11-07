#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/Luma Player.app"
if [[ ! -d "$app" ]]; then
  echo 'Build first: scripts/build-player-modern.sh' >&2; exit 1
fi
# Modern app accepts --input/--fps/--tier; use LaunchServices like a normal launch.
if [[ $# -eq 0 ]]; then exec open "$app"; fi
input="$1"; fps="${2:-48}"; tier="${3:-fast}"
[[ -f "$input" ]] || { echo 'Input video does not exist.' >&2; exit 2; }
[[ "$fps" == 48 || "$fps" == 60 ]] || { echo 'FPS must be 48 or 60.' >&2; exit 2; }
case "$tier" in fast|balanced|hq) ;; *) echo 'Tier must be fast, balanced or hq.' >&2; exit 2;; esac
input="$(cd "$(dirname "$input")" && pwd)/$(basename "$input")"
exec open "$app" --args --input "$input" --fps "$fps" --tier "$tier"
