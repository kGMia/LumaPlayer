// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

enum PlaybackShortcut: Equatable {
    case pause, mute, previousItem, nextItem
    case seek(backward: Bool, long: Bool)
    case frame(backward: Bool)
    case volume(up: Bool)
    case subtitleDelay(later: Bool, secondary: Bool)

    var permitsRepeat: Bool {
        switch self {
        case .pause, .mute, .previousItem, .nextItem: false
        case .seek, .frame, .volume, .subtitleDelay: true
        }
    }

    static func match(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> Self? {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        if keyCode == 123 || keyCode == 124 {
            let backward = keyCode == 123
            switch modifiers {
            case []: return .seek(backward: backward, long: false)
            case [.shift]: return .seek(backward: backward, long: true)
            case [.command]: return .frame(backward: backward)
            case [.option, .command]: return backward ? .previousItem : .nextItem
            default: return nil
            }
        }
        if modifiers == [.shift] {
            switch characters?.lowercased() {
            case "z": return .subtitleDelay(later: false, secondary: true)
            case "x": return .subtitleDelay(later: true, secondary: true)
            default: return nil
            }
        }
        guard modifiers.isEmpty else { return nil }
        switch keyCode {
        case 49: return .pause
        case 126: return .volume(up: true)
        case 125: return .volume(up: false)
        default:
            switch characters?.lowercased() {
            case "m": return .mute
            case ",": return .frame(backward: true)
            case ".": return .frame(backward: false)
            case "z": return .subtitleDelay(later: false, secondary: false)
            case "x": return .subtitleDelay(later: true, secondary: false)
            default: return nil
            }
        }
    }
}

struct PlaybackInputContext {
    let ownsKeyWindow: Bool
    let modal: Bool
    let focusedControl: Bool
    let popover: Bool
    var allowsWindowCommands: Bool { ownsKeyWindow && !modal }
    var allowsTransportKeys: Bool { allowsWindowCommands && !focusedControl && !popover }
}
