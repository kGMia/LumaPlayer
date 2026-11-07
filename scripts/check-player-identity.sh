#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/checks
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path build/checks/swift-modules \
 PlayerSystem/PlayerIdentity.swift tests/PlayerIdentitySmoke.swift -o build/checks/player-identity-smoke
build/checks/player-identity-smoke
python3 - <<'PY'
import ast
from pathlib import Path
for name in ['scripts/package-player.py', 'scripts/create-xcode-project.py', 'scripts/check-relocated-player.py']:
    ast.parse(Path(name).read_text(), filename=name)
print('PASS: packaging/generator Python syntax')
PY
