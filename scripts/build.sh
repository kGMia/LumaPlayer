#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
npm ci --ignore-scripts
npm run pack
if [[ "${1:-}" == "--native" ]]; then
  scripts/build-native.sh
  python3 scripts/package-native.py
fi
python3 scripts/package-source.py
python3 scripts/checksums.py
