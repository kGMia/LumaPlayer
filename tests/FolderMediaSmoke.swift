// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main struct FolderMediaSmoke {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("iive-folder-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for name in ["Episode10.mkv", "Episode2.MP4", "music.flac", ".hidden.mp4", "notes.txt"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let sub = root.appendingPathComponent("nested.mp4")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data().write(to: sub.appendingPathComponent("inside.mov"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.mp4"), withDestinationURL: root.appendingPathComponent("Episode2.MP4"))
        let actual = try FolderMedia.files(around: root.appendingPathComponent("Episode2.MP4")).map(\.lastPathComponent)
        guard actual == ["Episode2.MP4", "Episode10.mkv", "music.flac"] else {
            throw NSError(domain: "FolderMediaSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected result: \(actual)"])
        }
        print("PASS: local media, uppercase extensions, natural order, hidden files, subfolders, symlinks")
    }
}
