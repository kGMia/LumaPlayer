// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Keep command availability responsive to focus changes even while playback is
/// paused. Event dispatch always rechecks the live responder, not the telemetry snapshot.
@MainActor final class PlayerKeyboardFocus: NSObject {
    private weak var model: PlayerModel?
    init(model: PlayerModel) {
        self.model = model
        super.init()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
                     NSControl.textDidBeginEditingNotification, NSControl.textDidEndEditingNotification,
                     NSTextView.didChangeSelectionNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func refresh() {
        guard let model else { return }
        model.menuState.syncKeyboardFocus(from: model)
    }
    func handle(_ event: NSEvent) -> Bool {
        guard let model, !model.isMenuTracking else { return false }
        refresh()
        // Live Text owns Escape even when VisionKit or its text selection is
        // first responder. Never dismiss another window's sheet or popover.
        if event.keyCode == 53, model.frameActions.textSession.capture != nil,
           let window = NSApp?.keyWindow,
           window === model.window || window === model.videoView?.window,
           event.window == nil || event.window === window,
           window.attachedSheet == nil, window.sheetParent == nil, NSApp?.modalWindow == nil {
            model.frameActions.textSession.close()
            window.makeFirstResponder(model.videoView)
            return true
        }
        guard let action = PlaybackShortcut.match(keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags) else { return false }
        let context = model.playbackInputContext
        guard let keyWindow = NSApp?.keyWindow, event.window == nil || event.window === keyWindow else { return false }
        guard context.allowsTransportKeys else {
            // A focus change and key equivalent can arrive in the same run-loop
            // turn. Deliver conflicting keys directly to the native text editor
            // so a stale SwiftUI menu shortcut cannot eat typed text or caret motion.
            if let editor = keyWindow.firstResponder as? NSTextView {
                editor.keyDown(with: event)
                return true
            }
            return false
        }
        if !event.isARepeat || action.permitsRepeat { model.performPlaybackShortcut(action) }
        return true
    }
}

extension PlayerModel {
    var playbackInputContext: PlaybackInputContext {
        let keyWindow = NSApp?.keyWindow
        let owns = keyWindow != nil && (keyWindow === window || keyWindow === videoView?.window)
        let modal = fileDialogs.isBusy || showNetworkSheet || NSApp?.modalWindow != nil ||
            keyWindow?.sheetParent != nil || keyWindow?.attachedSheet != nil
        var control = keyWindow?.firstResponder is NSText
        // Native lists and controls retain their own keyboard navigation. Do not
        // identify SwiftUI's private responder classes or inspect implementation names.
        var view = keyWindow?.firstResponder as? NSView
        while let current = view, !control {
            control = current is NSControl || current is NSTableView || current is NSCollectionView
            view = current.superview
        }
        return PlaybackInputContext(ownsKeyWindow: owns, modal: modal, focusedControl: control,
                                    popover: queuePopover || quickSettings)
    }

    func performPlaybackShortcut(_ action: PlaybackShortcut) {
        let context = playbackInputContext
        guard context.allowsWindowCommands else { return }
        // Mouse/menu activation remains available while a control has focus, but
        // keyboard equivalents must honor that control's responder ownership.
        if let event = NSApp?.currentEvent, event.type == .keyDown,
           PlaybackShortcut.match(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                  modifiers: event.modifierFlags) != nil,
           !context.allowsTransportKeys { return }
        switch action {
        case .pause: togglePause()
        case .mute: toggleMute()
        case .seek(let backward, let long): skip(backward ? -1 : 1, long: long)
        case .frame(let backward): stepFrame(backward: backward)
        case .previousItem: previousOrRestart()
        case .nextItem: nextFile()
        case .volume(let up): changeVolume(up ? 1 : -1)
        case .subtitleDelay(let later, let secondary): stepSubtitleDelay(later: later, secondary: secondary)
        }
    }
}
