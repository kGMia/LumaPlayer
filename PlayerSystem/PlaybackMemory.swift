// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct PlaybackFileStamp: Codable, Equatable, Sendable {
    let size: Int
    let modified: Date
    static func read(_ path: String) -> Self? {
        guard path.hasPrefix("/"), let v = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
            v.isRegularFile == true, let size = v.fileSize, let modified = v.contentModificationDate else { return nil }
        return Self(size: size, modified: modified)
    }
}
struct PlaybackMemoryRecord: Codable, Sendable {
    let stamp: PlaybackFileStamp
    let updated: Date
    let position: Double
    let speed: Double
    let audio: String?
    let subtitle: String?
    let secondarySubtitle: String?
    static func embeddedSelection(_ id: String, type: String, tracks: [[String: Any]]) -> String? {
        if id == "no" { return "no" }
        guard let number = Int(id), tracks.contains(where: {
            ($0["id"] as? Int) == number && $0["type"] as? String == type && $0["external"] as? Bool != true
        }) else { return nil }
        return id
    }
    func options(resume: Bool, selections: Bool) -> [String: String] {
        var result: [String: String] = [:]
        if resume, position.isFinite, position > 5 { result["start"] = String(position) }
        if selections {
            if speed.isFinite, (0.1...8).contains(speed) { result["speed"] = String(speed) }
            for (key, value) in [("aid", audio), ("sid", subtitle), ("secondary-sid", secondarySubtitle)] {
                if let value, value == "no" || (Int(value).map { $0 > 0 } ?? false) { result[key] = value }
            }
            if subtitle != "no", subtitle != nil, subtitle == secondarySubtitle { result["secondary-sid"] = "no" }
        }
        return result
    }
}

@MainActor final class PlaybackMemory {
    private let defaults: UserDefaults
    private let key = "localPlaybackMemory.v1"
    private var records: [String: PlaybackMemoryRecord]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        records = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: PlaybackMemoryRecord].self, from: $0) } ?? [:]
    }
    func record(for path: String, stamp: PlaybackFileStamp) -> PlaybackMemoryRecord? {
        guard path.hasPrefix("/"), let record = records[path] else { return nil }
        guard record.stamp == stamp else { remove(path); return nil }
        return record
    }
    func save(_ record: PlaybackMemoryRecord, for path: String) {
        guard path.hasPrefix("/"), record.position.isFinite, record.position >= 0, record.speed.isFinite else { return }
        if let old = records[path], old.stamp == record.stamp,
           old.position == record.position, old.speed == record.speed,
           old.audio == record.audio, old.subtitle == record.subtitle,
           old.secondarySubtitle == record.secondarySubtitle { return }
        records[path] = record
        if records.count > 100 {
            let retained = records.sorted { $0.value.updated > $1.value.updated }.prefix(100)
            records = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        }
        persist()
    }
    func remove(_ path: String) { guard records.removeValue(forKey: path) != nil else { return }; persist() }
    func resetPosition(for path: String) {
        guard let old = records[path], old.position != 0 else { return }
        records[path] = PlaybackMemoryRecord(stamp: old.stamp, updated: Date(), position: 0, speed: old.speed,
            audio: old.audio, subtitle: old.subtitle, secondarySubtitle: old.secondarySubtitle)
        persist()
    }
    func clear() { records.removeAll(); defaults.removeObject(forKey: key) }
    private func persist() { if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: key) } }
}

/// Monotonic, once-per-open notice. Playback confirmation comes from mpv, not
/// from the saved preference or merely accepting the start option.
struct PlaybackResumeNotice {
    private var epoch: UInt64?
    private var dismissed = false
    private var expires = 0.0
    private var position: Double?
    mutating func update(epoch next: UInt64, confirmed: Double?, ready: Bool, now: Double) -> Double? {
        if epoch != next { epoch = next; dismissed = false; expires = 0; position = nil }
        guard ready, !dismissed else { return nil }
        if position != nil && confirmed == nil { dismiss(); return nil }
        if position == nil, let confirmed, confirmed.isFinite, confirmed > 5 {
            position = confirmed; expires = now + 6
        }
        if position != nil && now >= expires { dismiss(); return nil }
        return position
    }
    mutating func dismiss() { dismissed = true; position = nil }
}

/// Native option property lists are scoped to the unchanged source file, never
/// translated into mpv track numbers. Empty data represents an explicit Off.
@MainActor enum SystemTrackMemory {
    private static let key = "systemTrackMemory.v1"
    private struct Entry: Codable {
        let stamp: PlaybackFileStamp
        var updated: Date
        var selections: [String: Data]
    }
    private static func read(_ defaults: UserDefaults) -> [String: Entry] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }
    static func selections(for path: String, stamp: PlaybackFileStamp, defaults: UserDefaults = .standard) -> [String: Data] {
        guard let entry = read(defaults)[path], entry.stamp == stamp else { return [:] }
        return entry.selections
    }
    static func save(_ data: Data, type: String, path: String, stamp: PlaybackFileStamp, defaults: UserDefaults = .standard) {
        guard path.hasPrefix("/"), ["aid", "sid"].contains(type), data.count <= 65_536 else { return }
        var records = read(defaults)
        var entry = records[path].flatMap { $0.stamp == stamp ? $0 : nil } ?? Entry(stamp: stamp, updated: Date(), selections: [:])
        guard entry.selections[type] != data else { return }
        entry.selections[type] = data; entry.updated = Date(); records[path] = entry
        if records.count > 100 { records = Dictionary(uniqueKeysWithValues: records.sorted { $0.value.updated > $1.value.updated }.prefix(100).map { ($0.key, $0.value) }) }
        if let encoded = try? JSONEncoder().encode(records) { defaults.set(encoded, forKey: key) }
    }
    static func clear(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}

/// Conservative cross-backend matching: never use track order as identity.
struct TrackHandoffChoice: Equatable, Sendable {
    let language: String
    let title: String
    var disabled = false
    static let off = Self(language: "", title: "", disabled: true)
    private static func languageKey(_ value: String) -> String {
        let base = value.lowercased().replacingOccurrences(of: "_", with: "-")
        let parts = base.split(separator: "-", maxSplits: 1).map(String.init)
        let aliases = ["eng":"en", "zho":"zh", "chi":"zh", "jpn":"ja", "kor":"ko", "fra":"fr", "fre":"fr", "deu":"de", "ger":"de", "spa":"es", "ita":"it", "por":"pt", "rus":"ru"]
        guard let first = parts.first, !["und", "unknown"].contains(first) else { return "" }
        return (aliases[first] ?? first) + (parts.count > 1 ? "-" + parts[1] : "")
    }
    static func match(_ choice: Self, among candidates: [(String, Self)]) -> String? {
        if choice.disabled { return "no" }
        let language = languageKey(choice.language)
        let title = choice.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !language.isEmpty || !title.isEmpty else { return nil }
        var matches = candidates.filter { !$0.1.disabled }
        if !language.isEmpty {
            matches = matches.filter { languageKey($0.1.language) == language }
        }
        if !title.isEmpty {
            let titled = matches.filter { $0.1.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title }
            if !titled.isEmpty { matches = titled }
            else if language.isEmpty { return nil }
        }
        return matches.count == 1 ? matches[0].0 : nil
    }
}
