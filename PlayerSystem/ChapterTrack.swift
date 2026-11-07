// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Segment gaps are inset inside the original time coordinates. Seeking therefore
/// stays linear even with narrow or densely packed chapters.
struct ChapterTrack: View {
    let chapters: [MediaChapter]
    let markers: [PlaybackMarker]
    let duration: Double
    let position: Double
    let hover: Double?
    let width: CGFloat
    let compact: Bool
    private var starts: [Double] {
        let valid = chapters.map(\.time).filter { $0.isFinite && $0 > 0 && $0 < duration }
        return [0] + Array(Set(valid)).sorted()
    }
    var body: some View {
        let starts = starts
        let safeDuration = max(0.001, duration)
        ZStack(alignment: .leading) {
            ForEach(Array(starts.enumerated()), id: \.offset) { index, start in
                let end = index + 1 < starts.count ? starts[index + 1] : safeDuration
                let rawWidth = width * (end - start) / safeDuration
                let gap = starts.count > 1 ? min(2.5, rawWidth * 0.2) : 0
                let leftInset = index == 0 ? 0 : gap / 2
                let rightInset = index == starts.count - 1 ? 0 : gap / 2
                let segmentWidth = max(0, rawWidth - leftInset - rightInset)
                // Clip the continuous playhead coordinate to the visible segment;
                // compressing a chapter's progress into its gap-trimmed width
                // otherwise causes the fill edge to drift away from the thumb.
                let fill = width * (position - start) / safeDuration - leftInset
                let progress = segmentWidth > 0 ? min(1, max(0, fill / segmentWidth)) : 0
                let hovered = hover.map { $0 >= start && ($0 < end || index == starts.count - 1) } ?? false
                ChapterSegment(width: segmentWidth, progress: progress,
                               hovered: hovered, compact: compact)
                    .offset(x: width * start / safeDuration + leftInset)
            }
            ForEach(markers.filter { $0.time.isFinite && $0.time >= 0 && $0.time <= duration }) { marker in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.yellow)
                    .frame(width: 2.5, height: compact ? 8 : 11)
                    .offset(x: min(max(0, width * marker.time / safeDuration - 1), max(0, width - 2.5)))
            }
        }
        // offset changes drawing, not layout. Without an explicit full-width
        // frame, the parent centers the width of the longest chapter instead.
        .frame(width: max(0, width), height: compact ? 9 : 11, alignment: .leading)
        .allowsHitTesting(false)
    }
}
private struct ChapterSegment: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let width: CGFloat
    let progress: Double
    let hovered: Bool
    let compact: Bool
    private var height: CGFloat { hovered ? (compact ? 6 : 8) : (compact ? 3.5 : 4.5) }
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.primary.opacity(hovered ? 0.35 : 0.20))
            Rectangle().fill(.primary).frame(width: width * progress)
        }
        .frame(width: width, height: height)
        .clipShape(Capsule())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
    }
}
