#!/usr/bin/env python3
from pathlib import Path
import os, subprocess
root = Path(__file__).resolve().parents[1]
s = (root / 'native/Player/Modern/VideoInformation.swift').read_text()
implementation = s[s.index('struct MediaArtworkTheme:'):s.index('struct VideoInformationMetadataSections:')]
fixture = (root / 'tests/ArtworkThemeSmoke.swift').read_text()
out = root / 'build/checks/artwork-theme'
out.mkdir(parents=True, exist_ok=True)
(out / 'check.swift').write_text(fixture.replace('import SwiftUI', 'import SwiftUI\n' + implementation, 1))
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-cache-path', str(out / 'cache'), str(out / 'check.swift'), '-o', str(out / 'check')], env=env, check=True)
subprocess.run([str(out / 'check')], check=True)
