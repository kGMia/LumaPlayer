#!/usr/bin/env python3
"""Validate the production Spotlight path boundary without touching the system index."""
from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'PlayerSystem/MediaSystemServices.swift').read_text()
start = source.index('    nonisolated static func contains(')
end = source.index('    nonisolated private static func rebuild(', start)
method = source[start:end]
fixture = r'''
import Foundation
struct Scope {
METHOD
}
@main struct Check {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let folder = base.appendingPathComponent("library")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let outside = base.appendingPathComponent("outside.mkv")
        try Data().write(to: outside)
        let link = folder.appendingPathComponent("escape.mkv")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        precondition(Scope.contains(folder.appendingPathComponent("movie.mkv"), in: folder))
        precondition(!Scope.contains(folder, in: folder))
        precondition(!Scope.contains(base.appendingPathComponent("library-other/movie.mkv"), in: folder))
        precondition(!Scope.contains(link, in: folder))
        precondition(!Scope.contains(URL(string: "https://example.invalid/movie.mkv")!, in: folder))
        print("PASS: Spotlight local folder boundary, sibling-prefix and symlink escape rejection")
    }
}
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='luma-spotlight-') as scratch:
    folder = Path(scratch)
    (folder / 'check.swift').write_text(fixture)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-module-cache-path', str(folder / 'cache'), str(folder / 'check.swift'), '-o', str(folder / 'check')], env=env, check=True)
    subprocess.run([str(folder / 'check')], check=True)
