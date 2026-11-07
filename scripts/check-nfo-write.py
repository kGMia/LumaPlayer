#!/usr/bin/env python3
"""Small filesystem regression check; no player, media changes or GUI required."""
from pathlib import Path
import os
import subprocess
root = Path(__file__).resolve().parents[1]
source = (root / 'PlayerSystem/PlayQueueView.swift').read_text()
parser = source[source.index('struct MediaNFOMetadata:'):source.index('actor MediaNFOCache')]
writer = source[source.index('    @discardableResult\n    func saveLocalMetadata'):source.index('    func metadata(for key:')]
# Isolate filesystem writing from UI notifications/cache consumers; use the exact production method.
scaffold = 'import Foundation\n' + parser + '\nactor Writer {\nfunc store(_ key: String, value: MediaNFOMetadata?) {}\nstatic func locateLocalNFO(for url: URL, isFolder: Bool) -> URL? { nil }\n' + writer + '}\n'
out = root / 'build/checks/nfo-write'
out.mkdir(parents=True, exist_ok=True)
swift = out / 'check.swift'
swift.write_text(scaffold + (root / 'tests/NFOWriteSmoke.swift').read_text())
env = dict(os.environ)
env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-cache-path', str(out / 'cache'), str(swift), '-o', str(out / 'check')], env=env, check=True)
subprocess.run([str(out / 'check')], check=True)
