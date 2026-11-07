import Foundation

@main struct BrowserDirectoryWatcherSmoke {
    static func verify(_ condition: Bool, line: UInt = #line) {
        if !condition { FileHandle.standardError.write(Data("FAIL: watcher check line \(line)\n".utf8)); exit(1) }
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try fm.createDirectory(at: first, withIntermediateDirectories: true)
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        let watcher = BrowserDirectoryWatcher()
        defer { watcher.stop(); try? fm.removeItem(at: root) }
        watcher.watch([first])
        try Data().write(to: first.appendingPathComponent("movie.mkv"))
        for _ in 0..<30 where watcher.revision == 0 { try await Task.sleep(for: .milliseconds(100)) }
        verify(watcher.revision > 0)
        watcher.watch([second])
        let baseline = watcher.revision
        try Data().write(to: first.appendingPathComponent("old-folder.mkv"))
        try await Task.sleep(for: .milliseconds(700))
        verify(watcher.revision == baseline)
        try Data().write(to: second.appendingPathComponent("current-folder.mkv"))
        for _ in 0..<30 where watcher.revision == baseline { try await Task.sleep(for: .milliseconds(100)) }
        verify(watcher.revision > baseline)
        watcher.stop()
        let stopped = watcher.revision
        try Data().write(to: second.appendingPathComponent("after-stop.mkv"))
        try await Task.sleep(for: .milliseconds(700))
        verify(watcher.revision == stopped)
        print("PASS: directory change delivery, switched-directory isolation and stopped watcher cleanup")
    }
}
