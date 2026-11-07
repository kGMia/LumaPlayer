// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

struct VideoRatio: Identifiable {
    let id: String
    let title: String
    static let presets: [Self] = [
        .init(id: "16:9", title: "16:9"), .init(id: "4:3", title: "4:3"),
        .init(id: "1:1", title: "1:1"), .init(id: "235:100", title: "2.35:1"),
        .init(id: "239:100", title: "2.39:1"), .init(id: "9:16", title: "9:16")]
    static func number(_ text: String) -> Double? {
        let parts = text.split(separator: ":")
        if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), a > 0, b > 0 { return a / b }
        return Double(text)
    }
    static func selection(_ value: Any?, fallback: String) -> String {
        let text = (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
        if let exact = presets.first(where: { $0.id == text }) { return exact.id }
        if let number = number(text), number.isFinite, number > 0,
           let preset = presets.first(where: { abs((Self.number($0.id) ?? 0) - number) < 0.001 }) { return preset.id }
        return fallback
    }
}

@MainActor @Observable final class PlaybackGeometry {
    private(set) var epoch: UInt64 = 0
    private(set) var canLoop = false
    private(set) var hasVideo = false
    private(set) var start: Double?
    private(set) var end: Double?
    private(set) var aspect = "no"
    private(set) var crop = ""
    var hasLoopPoints: Bool { start != nil || end != nil }
    var loopDescription: String {
        if let start, let end { return "A \(Self.time(start)) → B \(Self.time(end))" }
        if let start { return String(localized: "A \(Self.time(start)) · Set B to loop") }
        return String(localized: "Off")
    }
    static func time(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < Double(Int.max / 100) else { return "—" }
        let s = Int(value)
        return String(format: "%d:%02d:%02d.%01d", s / 3600, s / 60 % 60, s % 60, Int(value * 10) % 10)
    }
    func update(_ snapshot: [String: Any]) {
        let nextEpoch = (snapshot["media-epoch"] as? NSNumber)?.uint64Value ?? 0
        if epoch != nextEpoch { epoch = nextEpoch }
        let loaded = snapshot["media-loaded"] as? Bool == true
        let duration = (snapshot["duration"] as? NSNumber)?.doubleValue ?? 0
        let enabled = loaded && snapshot["seekable"] as? Bool == true && duration.isFinite && duration > 0
        if canLoop != enabled { canLoop = enabled }
        let video = loaded && (snapshot["track-list"] as? [[String: Any]] ?? []).contains {
            $0["type"] as? String == "video" && $0["albumart"] as? Bool != true && $0["image"] as? Bool != true
        }
        if hasVideo != video { hasVideo = video }
        func point(_ key: String) -> Double? {
            guard enabled, let v = snapshot[key] as? NSNumber, v.doubleValue.isFinite,
                  v.doubleValue >= 0, v.doubleValue <= duration else { return nil }
            return v.doubleValue
        }
        let a = point("ab-loop-a"), b = point("ab-loop-b")
        if start != a { start = a }; if end != b { end = b }
        let newAspect = loaded ? VideoRatio.selection(snapshot["video-aspect-override"], fallback: "no") : "no"
        let newCrop = loaded ? VideoRatio.selection(snapshot["iive-crop-ratio"], fallback: "") : ""
        if aspect != newAspect { aspect = newAspect }; if crop != newCrop { crop = newCrop }
    }
    func reset() {
        canLoop = false; hasVideo = false; start = nil; end = nil; aspect = "no"; crop = ""
    }
}
