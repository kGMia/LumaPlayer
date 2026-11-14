// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// AppKit reports renderer/window transitions here, independently of SwiftUI body
/// updates or the main window being hidden by the mini player. Never replaces the
/// SwiftUI window delegate; the model owns one observer for its whole lifetime.
@MainActor final class PlayerWindowLifecycle: NSObject {
    private weak var model: PlayerModel?
    private weak var mainWindow: NSWindow?
    private weak var resizingWindow: NSWindow?
    private var closed = false

    init(model: PlayerModel) {
        self.model = model
        super.init()
        let names: [Notification.Name] = [
            NSWindow.didChangeScreenNotification,
            NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.willStartLiveResizeNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.willCloseNotification
        ]
        for name in names {
            NotificationCenter.default.addObserver(self, selector: #selector(receive(_:)), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func bind(to window: NSWindow) {
        guard mainWindow !== window else { return }
        resetTransientState()
        mainWindow = window
        closed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.resizeIncrements = NSSize(width: 1, height: 1)
        if let model {
            model.windowModes.updateMainWindowLevel(model)
        }
    }

    func resetTransientState() {
        resizingWindow = nil
        if model?.liveResizing == true { model?.liveResizing = false }
    }

    @objc private func receive(_ notification: Notification) {
        // NSWindow lifecycle notifications are delivered synchronously on AppKit's
        // main thread: preserve will/did ordering around render-queue draining.
        guard let model, let window = notification.object as? NSWindow else { return }
        let isMain = window === mainWindow && window === model.window
        let isRenderer = window === model.videoView?.window
        guard isMain || isRenderer else { return }

        if notification.name == NSWindow.didBecomeKeyNotification {
            guard isMain, window.isVisible else { return }
            closed = false
            if model.miniPlayer && !model.windowTransition { model.windowModes.restore(model) }
            if let view = model.videoView, model.session == nil { model.attach(view) }
            return
        }
        guard !closed else { return }

        switch notification.name {
        case NSWindow.didChangeScreenNotification:
            if isRenderer && model.colorProfile == "display" { model.applyColorProfile() }
        case NSWindow.willEnterFullScreenNotification where isMain:
            model.windowModes.beginFullScreen(model)
            model.fullScreen = true
        case NSWindow.willExitFullScreenNotification where isMain:
            model.windowModes.beginFullScreen(model)
        case NSWindow.didEnterFullScreenNotification where isMain:
            model.fullScreen = true
            model.windowModes.finishFullScreen(model)
        case NSWindow.didExitFullScreenNotification where isMain:
            model.fullScreen = false
            model.windowModes.finishFullScreen(model)
        case NSWindow.willStartLiveResizeNotification:
            guard resizingWindow !== window else { return }
            resizingWindow = window
            model.liveResizing = true
        case NSWindow.didEndLiveResizeNotification:
            guard resizingWindow === window else { return }
            resetTransientState()
            model.enhancementPlanResumeAt = max(model.enhancementPlanResumeAt,
                ProcessInfo.processInfo.systemUptime + 0.12)
            model.telemetry.flush()
            model.apply()
        case NSWindow.willCloseNotification where isMain:
            // Ignore nested/duplicate close events during mini-window teardown.
            closed = true
            resetTransientState()
            model.shutdown()
        case NSWindow.willCloseNotification:
            if resizingWindow === window { resetTransientState() }
        default: break
        }
    }
}
