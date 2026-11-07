// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Bounded metadata cache; never create another mpv session for queue artwork.
struct QueueMetadata: Sendable {
    var duration: Double?
    var size: Int64?
    var cover: Data?
    var subtitleCount: Int?
}
