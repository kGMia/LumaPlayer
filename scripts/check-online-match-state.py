#!/usr/bin/env python3
"""Offline regression: revalidation must not temporarily hide a confirmed match."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'PlayerSystem/OnlineMovieMetadata.swift').read_text()
models = source[source.index('struct OnlineMovie:'):source.index('struct MovieMetadataError:')]
library = source[source.index('@MainActor final class OnlineMovieLibrary'):].replace('UserDefaults.standard', 'TestStore.defaults')
stamp = (root / 'PlayerSystem/PlaybackMemory.swift').read_text().split('struct PlaybackMemoryRecord:')[0]
fixture = r'''
@MainActor enum TestStore {
    static let suite = "LumaMatchStateTest." + UUID().uuidString
    static let defaults = UserDefaults(suiteName: suite)!
}
actor OnlinePosterCache {
    static let shared = OnlinePosterCache()
    func cancelPending() {}
    func prefetch(_ urls: [URL]) {}
}
@main struct Check {
    @MainActor static func main() async throws {
        defer { TestStore.defaults.removePersistentDomain(forName: TestStore.suite) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("original".utf8).write(to: file)
        let library = OnlineMovieLibrary(); library.enabled = true
        let movie = OnlineMovie(id: 7, title: "Test", originalTitle: nil, releaseDate: nil, overview: nil, runtime: nil, genres: nil, credits: nil)
        library.confirm(movie, path: file.path, stamp: PlaybackFileStamp.read(file.path)!)
        let revision = library.searchRevision
        library.confirmBatch([(file.path, PlaybackFileStamp.read(file.path)!, movie), (file.path, PlaybackFileStamp.read(file.path)!, movie)])
        precondition(library.searchRevision == revision + 1, "Batch published more than once")
        library.confirmBatch([])
        precondition(library.searchRevision == revision + 1, "Empty batch changed the index")
        let restored = OnlineMovieLibrary()
        let indexed = await restored.searchIndex(paths: [file.path])
        precondition(indexed[file.path]?.contains("Test") == true, "Persisted offscreen match not indexed")
        restored.enabled = false
        let disabled = await restored.searchIndex(paths: [file.path])
        precondition(disabled.isEmpty)
        let first = Task { await library.validate(file.path) }
        await Task.yield()
        precondition(library.movie(for: file.path)?.id == 7, "Revalidation hid a valid match")
        await first.value
        precondition(library.movie(for: file.path)?.id == 7)
        let concurrent = Task { await library.validate(file.path) }
        library.remove(file.path)
        await concurrent.value
        precondition(library.movie(for: file.path) == nil)
        let removedIndex = await library.searchIndex(paths: [file.path])
        precondition(removedIndex.isEmpty)
        library.confirm(movie, path: file.path, stamp: PlaybackFileStamp.read(file.path)!)
        let renamed = file.appendingPathExtension("renamed")
        try FileManager.default.moveItem(at: file, to: renamed)
        await library.relocate(from: file.path, to: renamed.path)
        precondition(library.movie(for: renamed.path)?.id == 7 && library.movie(for: file.path) == nil)
        try FileManager.default.moveItem(at: renamed, to: file)
        await library.relocate(from: renamed.path, to: file.path)
        precondition(library.movie(for: file.path)?.id == 7)
        try Data("changed media with different length".utf8).write(to: file)
        await library.validate(file.path)
        precondition(library.movie(for: file.path) == nil, "Changed file retained its match")
        let staleIndex = await library.searchIndex(paths: [file.path])
        precondition(staleIndex.isEmpty, "Changed file remained searchable")
        print("PASS: search index persistence/disable/removal/invalidation; stable validation, removal during validation, changed-file invalidation")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='luma-match-state-') as work:
    swift = Path(work) / 'check.swift'
    swift.write_text('import Foundation\nimport Combine\nimport CryptoKit\n' + stamp + models + library + fixture)
    binary = Path(work) / 'check'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
