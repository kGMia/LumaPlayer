#!/usr/bin/env python3
from pathlib import Path
import subprocess, os
root = Path(__file__).resolve().parents[1]
s = (root / 'PlayerSystem/PlayQueueView.swift').read_text()
implementation = s[s.index('private struct BrowserStack:'):s.index('private struct BrowserMediaSection:')]
models = (root / 'PlayerSystem/OnlineMovieMetadata.swift').read_text()
implementation = models[models.index('struct OnlineMovie:'):models.index('struct MovieMetadataError:')] + '\n' + implementation
fixture = (root / 'tests/BrowserGroupingSmoke.swift').read_text()
out = root / 'build/checks/browser-grouping'
out.mkdir(parents=True, exist_ok=True)
(out / 'check.swift').write_text(fixture.replace('func checkGrouping()', implementation + '\nfunc checkGrouping()', 1))
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-cache-path', str(out / 'cache'), str(out / 'check.swift'), '-o', str(out / 'check')], env=env, check=True)
subprocess.run([str(out / 'check')], check=True)
