// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main struct PlaybackPreferencesSmoke {
    @MainActor static func main() {
        let suite = "org.iive.preferences-smoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlaybackPreferences(defaults: defaults)
        precondition(preferences.trackOptions["sid"] == "auto")
        precondition(preferences.saveLanguages(audio: " JA, en, ja ", subtitles: "zh-Hans, zh, en", automatic: false))
        preferences.selectDevice("coreaudio/test-dac")
        let restored = PlaybackPreferences(defaults: defaults)
        precondition(restored.audioLanguages == "ja,en" && restored.subtitleLanguages == "zh-hans,zh,en")
        precondition(restored.audioDevice == "coreaudio/test-dac" && restored.trackOptions["sid"] == "no")
        precondition(!restored.saveLanguages(audio: "en", subtitles: "zh,,en", automatic: true))
        precondition(restored.audioLanguages == "ja,en" && !restored.automaticSubtitles, "Invalid edits must not partially save")
        for invalid in ["en;sid=1", "English", "en,", "zh/../../x", String(repeating: "en,", count: 100)] {
            precondition(TrackLanguages.normalize(invalid) == nil)
        }
        precondition(TrackLanguages.normalize("pt-BR,jpn,zh-Hant-TW") == "pt-br,jpn,zh-hant-tw")
        let choices: [[String: Any]] = [["name":"auto"], ["name":"coreaudio/test-dac", "description":"USB DAC"],
                                      ["name":"coreaudio/test-dac"], ["description":"invalid"]]
        restored.update(["audio-device-list":choices])
        precondition(restored.devices.map(\.id) == ["auto", "coreaudio/test-dac"])
        restored.update(["audio-device-list":[], "iive-audio-output-status":"Unavailable"])
        precondition(restored.devices == [.system] && restored.audioDevice == "coreaudio/test-dac",
                     "Disconnect must preserve the preferred device")
        // Per-file remembered selection must override auto/disabled defaults.
        let record = PlaybackMemoryRecord(stamp: .init(size: 1, modified: .distantPast), updated: .now,
            position: 0, speed: 1, audio: "2", subtitle: "3", secondarySubtitle: nil)
        var options = restored.trackOptions
        options.merge(record.options(resume: false, selections: true)) { _, saved in saved }
        precondition(options["aid"] == "2" && options["sid"] == "3" && options["alang"] == "ja,en")
        let nativeStamp = PlaybackFileStamp(size: 42, modified: .distantPast)
        SystemTrackMemory.save(Data([1, 2, 3]), type: "aid", path: "/test.mov", stamp: nativeStamp, defaults: defaults)
        SystemTrackMemory.save(Data(), type: "sid", path: "/test.mov", stamp: nativeStamp, defaults: defaults)
        let native = SystemTrackMemory.selections(for: "/test.mov", stamp: nativeStamp, defaults: defaults)
        precondition(native["aid"] == Data([1, 2, 3]) && native["sid"] == Data())
        precondition(SystemTrackMemory.selections(for: "/test.mov", stamp: .init(size: 43, modified: .distantPast), defaults: defaults).isEmpty)
        SystemTrackMemory.clear(defaults: defaults)
        precondition(SystemTrackMemory.selections(for: "/test.mov", stamp: nativeStamp, defaults: defaults).isEmpty)
        let english = TrackHandoffChoice(language: "eng", title: "")
        let main = TrackHandoffChoice(language: "en", title: "Main")
        let commentary = TrackHandoffChoice(language: "en", title: "Commentary")
        precondition(TrackHandoffChoice.match(english, among: [("4", main)]) == "4")
        precondition(TrackHandoffChoice.match(english, among: [("4", main), ("7", commentary)]) == nil)
        precondition(TrackHandoffChoice.match(commentary, among: [("4", main), ("7", commentary)]) == "7")
        precondition(TrackHandoffChoice.match(.off, among: []) == "no")
        precondition(TrackHandoffChoice.match(.init(language: "und", title: ""), among: [("4", main)]) == nil)
        precondition(TrackHandoffChoice.match(.init(language: "zh-Hant", title: ""), among: [("1", .init(language: "zh-Hans", title: ""))]) == nil)
        print("PASS: track handoff aliases, unique match, ambiguity, Off and script separation;")
        print("PASS: native track persistence, Off, file replacement and clear;")
        print("PASS: language validation, atomic persistence, remembered track precedence and device disconnect state; no GUI or audio opened.")
    }
}
