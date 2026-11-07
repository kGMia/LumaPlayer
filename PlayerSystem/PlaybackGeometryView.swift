// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ABLoopMenu: View {
    let model: PlayerModel
    var body: some View {
        let loop = model.playbackGeometry
        Menu {
            Text(loop.loopDescription)
            Button("Set A at Current Position", systemImage: "a.circle") { model.setLoopPoint("a") }
                .disabled(!loop.canLoop)
            Button("Set B and Start Loop", systemImage: "b.circle") { model.setLoopPoint("b") }
                .disabled(!loop.canLoop || loop.start == nil)
            Button("Clear A–B Loop", systemImage: "xmark.circle") { model.setLoopPoint("clear") }
                .disabled(!loop.hasLoopPoints)
        } label: { Label("A–B Loop", systemImage: "repeat") }
    }
}

struct VideoGeometryControls: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        Picker(selection: Binding(get: { model.playbackGeometry.aspect }, set: { model.setGeometry("video-aspect-override", $0) })) {
            Text("Original").tag("no")
            ForEach(VideoRatio.presets) { Text($0.title).tag($0.id) }
        } label: { Label("Aspect Ratio", systemImage: "aspectratio") }
        .disabled(!model.playbackGeometry.hasVideo)
        Picker(selection: Binding(get: { model.playbackGeometry.crop }, set: { model.setGeometry("video-crop", $0) })) {
            Text("Original / Container Crop").tag("")
            ForEach(VideoRatio.presets) { Text($0.title).tag($0.id) }
        } label: { Label("Center Crop", systemImage: "crop") }
        .disabled(!model.playbackGeometry.hasVideo)
        Picker(selection: $model.deinterlaceMode) {
            Text("Off").tag("no"); Text("Auto · Frame Flags").tag("auto"); Text("On").tag("yes")
        } label: { Label("Deinterlace", systemImage: "line.3.horizontal") }
    }
}

struct ABLoopOverlay: View {
    let loop: PlaybackGeometry
    let duration: Double
    let width: CGFloat
    var body: some View {
        if let a = loop.start, duration.isFinite, duration > 0, width > 0 {
            let x = min(width, max(0, width * a / duration))
            ZStack(alignment: .leading) {
                if let b = loop.end {
                    let right = min(width, max(0, width * b / duration))
                    Capsule().fill(.cyan.opacity(0.45)).frame(width: max(0, right - x), height: 5).offset(x: x)
                    point("B", at: right)
                }
                point("A", at: x)
            }.frame(width: width, height: 18, alignment: .leading)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
    private func point(_ title: String, at x: CGFloat) -> some View {
        Text(title).font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.black).frame(width: 12, height: 14)
            .background(.cyan, in: RoundedRectangle(cornerRadius: 3))
            .offset(x: min(max(0, x - 6), max(0, width - 12)))
    }
}

extension PlayerModel {
    func setLoopPoint(_ point: String) {
        guard point == "clear" || (playbackGeometry.canLoop && timeline.pendingSeek == nil) else { return }
        session?.setLoopPoint(point, expectedEpoch: playbackGeometry.epoch)
    }
    func setGeometry(_ option: String, _ value: String) {
        guard playbackGeometry.hasVideo else { return }
        session?.setVideoGeometry(option, value: value, expectedEpoch: playbackGeometry.epoch)
    }
    func applyDeinterlace() {
        // Submit the FI-free plan before enabling deinterlacing. mpv's built-in
        // pre-filter owns field detection, conversion and doubled output PTS.
        UserDefaults.standard.set(deinterlaceMode, forKey: "deinterlaceMode")
        apply()
    }
}
