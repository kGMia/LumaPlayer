// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@main struct PlaybackShortcutSmoke {
    static func main() {
        func key(_ code: UInt16, _ text: String? = nil, _ flags: NSEvent.ModifierFlags = []) -> PlaybackShortcut? {
            PlaybackShortcut.match(keyCode: code, characters: text, modifiers: flags)
        }
        precondition(key(49, " ") == .pause)
        precondition(key(123, nil, [.function, .numericPad]) == .seek(backward: true, long: false))
        precondition(key(124, nil, [.shift]) == .seek(backward: false, long: true))
        precondition(key(123, nil, [.command]) == .frame(backward: true))
        precondition(key(124, nil, [.command, .option]) == .nextItem)
        precondition(key(126) == .volume(up: true))
        precondition(key(46, "M", [.capsLock]) == .mute)
        precondition(key(43, ",") == .frame(backward: true))
        precondition(key(47, ".") == .frame(backward: false))
        // Preserve word navigation, selection, copy, IME and unsupported chords.
        precondition(key(123, nil, [.option]) == nil)
        precondition(key(124, nil, [.command, .shift]) == nil)
        precondition(key(8, "c", [.command]) == nil)
        precondition(key(49, " ", [.control]) == nil)
        precondition(key(46, "ь") == nil)
        precondition(key(47, ">", [.shift]) == nil)
        precondition(!PlaybackShortcut.pause.permitsRepeat && !PlaybackShortcut.nextItem.permitsRepeat)
        precondition(PlaybackShortcut.seek(backward: false, long: false).permitsRepeat)
        precondition(PlaybackShortcut.volume(up: false).permitsRepeat)
        for owns in [false, true] {
            for modal in [false, true] {
                for control in [false, true] {
                    for popover in [false, true] {
                        let context = PlaybackInputContext(ownsKeyWindow: owns, modal: modal, focusedControl: control, popover: popover)
                        precondition(context.allowsWindowCommands == (owns && !modal))
                        precondition(context.allowsTransportKeys == (owns && !modal && !control && !popover))
                    }
                }
            }
        }
        print("PASS: transport key mapping, modifier/layout handling, repeat policy and window/input scope matrix; no GUI opened.")
    }
}
