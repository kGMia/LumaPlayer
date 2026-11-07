// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct PlaybackPreferencesView: View {
    @ObservedObject var model: PlayerModel
    let preferences: PlaybackPreferences
    @State private var audio: String
    @State private var subtitles: String
    @State private var automatic: Bool
    @State private var validation = ""
    init(model: PlayerModel) {
        self.model = model
        preferences = model.playbackPreferences
        _audio = State(initialValue: model.playbackPreferences.audioLanguages)
        _subtitles = State(initialValue: model.playbackPreferences.subtitleLanguages)
        _automatic = State(initialValue: model.playbackPreferences.automaticSubtitles)
    }
    private var changed: Bool {
        audio != preferences.audioLanguages || subtitles != preferences.subtitleLanguages || automatic != preferences.automaticSubtitles
    }
    var body: some View {
        Section("Audio Output") {
            SystemPlaybackNotice(model: model)
            Picker("Device", selection: Binding(get: { preferences.audioDevice }, set: { model.selectAudioOutput($0) })) {
                ForEach(preferences.devices) { Text($0.title).tag($0.id) }
                if !preferences.devices.contains(where: { $0.id == preferences.audioDevice }) {
                    Text("Saved Device · Unavailable").tag(preferences.audioDevice)
                }
            }
            .disabled(model.systemHDRActive)
            if !model.systemHDRActive && !preferences.outputStatus.isEmpty {
                Text(preferences.outputStatus).font(.caption).foregroundStyle(.secondary)
            }
            Text("Follows the system default when the saved device is unavailable, and returns to the saved device when it reconnects. Switching may briefly interrupt audio.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Preferred Track Languages") {
            Text("Language preferences also apply to new system HDR sessions. System track selections are independent of mpv per-file track memory.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Audio", text: $audio, prompt: Text("e.g. ja, en"))
            TextField("Subtitles", text: $subtitles, prompt: Text("e.g. zh-Hans, zh, en"))
            Toggle("Automatically Select Subtitles", isOn: $automatic)
            HStack {
                Button("Use System Languages") {
                    let languages = Locale.preferredLanguages.filter { TrackLanguages.normalize($0) != nil }.prefix(12).joined(separator: ",")
                    audio = languages; subtitles = languages
                }
                Spacer()
                Button("Apply to New Media", action: save).disabled(!changed)
            }
            if !validation.isEmpty { Text(validation).font(.caption).foregroundStyle(.red) }
            Text("Enter language codes in priority order, separated by commas. Leave blank for the player's default selection. Applies when opening media; remembered per-file tracks and reconnect recovery take priority. Current tracks stay unchanged.")
                .font(.caption).foregroundStyle(.secondary)
        }.onSubmit(save)
    }
    private func save() {
        guard preferences.saveLanguages(audio: audio, subtitles: subtitles, automatic: automatic) else {
            validation = String(localized: "Use up to 12 language tags, such as en, jpn, zh-Hans or pt-BR, separated by commas.")
            return
        }
        audio = preferences.audioLanguages; subtitles = preferences.subtitleLanguages; validation = ""
        model.session?.configureTrackPreferences(preferences.trackOptions)
    }
}

extension PlayerModel {
    func selectAudioOutput(_ id: String) {
        playbackPreferences.selectDevice(id)
        session?.selectPreferredAudioDevice(id)
    }
}
