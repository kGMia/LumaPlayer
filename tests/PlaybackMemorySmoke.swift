// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main enum PlaybackMemorySmoke {
    @MainActor static func main() throws {
        let suite = "iive-playback-memory-smoke-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("sample.bin")
        try Data([1]).write(to: file)
        let stamp = PlaybackFileStamp.read(file.path)!
        let store = PlaybackMemory(defaults: defaults)
        let record = PlaybackMemoryRecord(stamp: stamp, updated: Date(), position: 42, speed: 1.25,
            audio: "2", subtitle: "no", secondarySubtitle: "3")
        store.save(record, for: file.path)
        let persisted = defaults.data(forKey: "localPlaybackMemory.v1")
        let unchanged = PlaybackMemoryRecord(stamp: stamp, updated: Date().addingTimeInterval(10),
            position: record.position, speed: record.speed, audio: record.audio,
            subtitle: record.subtitle, secondarySubtitle: record.secondarySubtitle)
        store.save(unchanged, for: file.path)
        store.remove("/missing-file")
        precondition(defaults.data(forKey: "localPlaybackMemory.v1") == persisted)
        let reopened = PlaybackMemory(defaults: defaults)
        let saved = reopened.record(for: file.path, stamp: stamp)!
        precondition(saved.options(resume: true, selections: true) ==
            ["start":"42.0", "speed":"1.25", "aid":"2", "sid":"no", "secondary-sid":"3"])
        precondition(saved.options(resume: false, selections: false).isEmpty)
        precondition(saved.options(resume: true, selections: false) == ["start":"42.0"])
        precondition(saved.options(resume: false, selections: true)["start"] == nil)
        reopened.resetPosition(for: file.path)
        let restarted = PlaybackMemory(defaults: defaults).record(for: file.path, stamp: stamp)!
        precondition(restarted.options(resume: true, selections: true)["start"] == nil)
        precondition(restarted.speed == 1.25 && restarted.secondarySubtitle == "3")
        let tracks: [[String: Any]] = [["id":2,"type":"audio"], ["id":3,"type":"sub","external":true]]
        precondition(PlaybackMemoryRecord.embeddedSelection("2", type: "audio", tracks: tracks) == "2")
        precondition(PlaybackMemoryRecord.embeddedSelection("3", type: "sub", tracks: tracks) == nil)
        precondition(PlaybackMemoryRecord.embeddedSelection("4", type: "audio", tracks: tracks) == nil)
        precondition(PlaybackMemoryRecord.embeddedSelection("no", type: "sub", tracks: tracks) == "no")
        try Data([1,2,3]).write(to: file)
        let changed = PlaybackFileStamp.read(file.path)!
        precondition(reopened.record(for: file.path, stamp: changed) == nil)
        precondition(PlaybackMemory(defaults: defaults).record(for: file.path, stamp: stamp) == nil)
        store.save(record, for: "https://example.com/private.mp4?token=secret")
        precondition(store.record(for: "https://example.com/private.mp4?token=secret", stamp: stamp) == nil)
        for i in 0..<110 {
            store.save(PlaybackMemoryRecord(stamp: stamp, updated: Date(timeIntervalSince1970: Double(i)),
                position: 10, speed: 1, audio: nil, subtitle: nil, secondarySubtitle: nil), for: "/clip-\(i)")
        }
        precondition(store.record(for: "/clip-0", stamp: stamp) == nil)
        precondition(store.record(for: "/clip-109", stamp: stamp) != nil)
        store.clear()
        precondition(PlaybackMemory(defaults: defaults).record(for: "/clip-109", stamp: stamp) == nil)
        var notice = PlaybackResumeNotice()
        precondition(notice.update(epoch: 1, confirmed: nil, ready: true, now: 0) == nil)
        precondition(notice.update(epoch: 1, confirmed: 42, ready: false, now: 10) == nil)
        precondition(notice.update(epoch: 1, confirmed: 42, ready: true, now: 11) == 42)
        precondition(notice.update(epoch: 1, confirmed: 42, ready: true, now: 16.9) == 42)
        precondition(notice.update(epoch: 1, confirmed: 42, ready: true, now: 17) == nil)
        precondition(notice.update(epoch: 1, confirmed: 42, ready: true, now: 18) == nil)
        precondition(notice.update(epoch: 2, confirmed: 60, ready: true, now: 19) == 60)
        notice.dismiss()
        precondition(notice.update(epoch: 2, confirmed: 60, ready: true, now: 20) == nil)
        precondition(notice.update(epoch: 3, confirmed: nil, ready: true, now: 21) == nil)
        precondition(notice.update(epoch: 3, confirmed: .nan, ready: true, now: 22) == nil)
        precondition(notice.update(epoch: 3, confirmed: 80, ready: true, now: 23) == 80)
        precondition(notice.update(epoch: 3, confirmed: nil, ready: true, now: 24) == nil)
        print("PASS: playback memory, start-over preserves choices, confirmed-only notice, expiry, dismissal and file changes")
    }
}
