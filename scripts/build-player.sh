#!/bin/bash
# Compatibility entry point: never overwrite the modern app with the old host.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == "--host-only" ]]; then shift; fi
exec scripts/build-player-modern.sh "$@"
