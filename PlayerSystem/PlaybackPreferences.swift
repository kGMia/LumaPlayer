// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

enum TrackLanguages {
    /// A deliberately bounded subset of BCP-47 suitable for mpv's language list.
    /// Keep ordering; mpv handles equivalent ISO 639-1/639-2 tags itself.
    static func normalize(_ text: String) -> String? {
        guard text.count <= 256 else { return nil }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        var tags: [String] = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let tag = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard tag.range(of: "^[a-z]{2,3}(-[a-z0-9]{2,8})*$", options: .regularExpression) != nil else { return nil }
            if !tags.contains(tag) { tags.append(tag) }
        }
        guard tags.count <= 12 else { return nil }
        return tags.joined(separator: ",")
    }
}

struct AudioOutputChoice: Identifiable, Equatable {
    let id: String
    let title: String
    static let system = Self(id: "auto", title: String(localized: "System Default"))
    static func read(_ value: Any?) -> [Self] {
        var result = [system]
        for item in value as? [[String: Any]] ?? [] {
            guard let name = item["name"] as? String, !name.isEmpty,
                  !result.contains(where: { $0.id == name }) else { continue }
            let label = item["description"] as? String ?? ""
            result.append(Self(id: name, title: label.isEmpty ? name : label))
        }
        return result
    }
}

@MainActor @Observable final class PlaybackPreferences {
    private(set) var audioDevice: String
    private(set) var audioLanguages: String
    private(set) var subtitleLanguages: String
    private(set) var automaticSubtitles: Bool
    private(set) var devices: [AudioOutputChoice] = [.system]
    private(set) var outputStatus = ""
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        audioDevice = defaults.string(forKey: "preferredAudioDevice") ?? "auto"
        audioLanguages = TrackLanguages.normalize(defaults.string(forKey: "preferredAudioLanguages") ?? "") ?? ""
        subtitleLanguages = TrackLanguages.normalize(defaults.string(forKey: "preferredSubtitleLanguages") ?? "") ?? ""
        automaticSubtitles = defaults.object(forKey: "automaticSubtitleSelection") as? Bool ?? true
    }
    var trackOptions: [String: String] {
        ["alang": audioLanguages, "slang": subtitleLanguages,
         "aid": "auto", "sid": automaticSubtitles ? "auto" : "no", "secondary-sid": "no"]
    }
    func selectDevice(_ id: String) {
        audioDevice = id
        defaults.set(id, forKey: "preferredAudioDevice")
    }
    @discardableResult func saveLanguages(audio: String, subtitles: String, automatic: Bool) -> Bool {
        guard let audio = TrackLanguages.normalize(audio), let subtitles = TrackLanguages.normalize(subtitles) else { return false }
        audioLanguages = audio; subtitleLanguages = subtitles; automaticSubtitles = automatic
        defaults.set(audio, forKey: "preferredAudioLanguages")
        defaults.set(subtitles, forKey: "preferredSubtitleLanguages")
        defaults.set(automatic, forKey: "automaticSubtitleSelection")
        return true
    }
    func update(_ snapshot: [String: Any]) {
        let next = AudioOutputChoice.read(snapshot["audio-device-list"])
        if devices != next { devices = next }
        let status = snapshot["iive-audio-output-status"] as? String ?? ""
        if outputStatus != status { outputStatus = status }
    }
}
