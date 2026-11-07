#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/checks
# Compile the production state declarations without the player/GPU runtime.
python3 - <<'PY'
from pathlib import Path
source = Path('native/Player/Modern/PlayerModel.swift').read_text()
start = source.index('@MainActor final class PlayerTelemetryState')
end = source.index('/// Dedicated low-frequency state', start)
Path('build/checks/TelemetryStates.swift').write_text('import Foundation\nimport Observation\n' + source[start:end])
PY
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/checks/swift-modules \
 build/checks/TelemetryStates.swift tests/TelemetryObservationSmoke.swift -o build/checks/telemetry-observation-smoke
build/checks/telemetry-observation-smoke
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/checks/swift-modules \
 PlayerSystem/PlayerTimeline.swift tests/TimelineSeekSmoke.swift -o build/checks/ui-timeline-smoke
build/checks/ui-timeline-smoke
