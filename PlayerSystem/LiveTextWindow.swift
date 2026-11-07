// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Observation
import VisionKit

/// Transient capture state, never restored between launches. Window presentation
/// is supplied by SwiftUI; frame capture and OCR do not own an NSWindow.
@MainActor @Observable final class LiveTextSession {
    static let windowID = "live-text"
    @MainActor struct Capture: Identifiable {
        let id = UUID()
        let source: String
        let result = FrameTextResult()
    }
    private(set) var capture: Capture?
    @ObservationIgnored var presentWindow: (() -> Void)?
    @ObservationIgnored var onCancelCapture: (() -> Void)?
    @ObservationIgnored var dismissWindow: (() -> Void)?

    func contains(_ id: UUID) -> Bool { capture?.id == id }
    func focusIfBusy() -> Bool {
        guard capture?.result.busy == true else { return false }
        presentWindow?()
        return true
    }
    func begin(source: String) -> Capture {
        onCancelCapture?(); onCancelCapture = nil
        capture?.result.cancel()
        let next = Capture(source: source)
        capture = next
        presentWindow?()
        return next
    }
    func close() {
        windowDidClose()
        dismissWindow?()
    }
    func windowDidClose() {
        onCancelCapture?(); onCancelCapture = nil
        let previous = capture
        capture = nil
        previous?.result.cancel()
    }
}

struct LiveTextWindow: View {
    let session: LiveTextSession
    var body: some View {
        Group {
            if let capture = session.capture {
                FrameTextView(result: capture.result, source: capture.source, onClose: session.close)
                    .id(capture.id)
            } else {
                ContentUnavailableView("No Captured Frame", systemImage: "text.viewfinder",
                    description: Text("Choose Live Text from the video's contextual menu to recognize text."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

@MainActor @Observable final class FrameTextResult {
    enum Phase: Equatable { case capturing, recognizing, ready, failed(String), cancelled }
    private(set) var phase: Phase = .capturing
    private(set) var transcript = ""
    private(set) var analysis: ImageAnalysis?
    private(set) var image: NSImage?
    @ObservationIgnored private var task: Task<Void, Never>?
    var busy: Bool { phase == .capturing || phase == .recognizing }
    func fail(_ message: String) {
        guard phase != .cancelled else { return }
        phase = .failed(message)
    }
    func recognize(_ image: NSImage) {
        guard phase != .cancelled else { return }
        task?.cancel()
        self.image = image; phase = .recognizing
        task = Task { @MainActor [weak self] in
            do {
                let result = try await ImageAnalyzer().analyze(image, orientation: .up, configuration: .init([.text]))
                guard !Task.isCancelled, let self, self.phase != .cancelled else { return }
                self.analysis = result
                self.transcript = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                self.phase = .ready
                self.task = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail("Text recognition failed: " + error.localizedDescription)
                self?.task = nil
            }
        }
    }
    func cancel() {
        task?.cancel(); task = nil
        image = nil; analysis = nil; transcript = ""; phase = .cancelled
    }
}

private struct FrameTextView: View {
    let result: FrameTextResult
    let source: String
    let onClose: () -> Void
    @State private var showTranscript = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.title3)
                }.buttonStyle(.plain).help("Close Live Text")
                Label("Live Text", systemImage: "text.viewfinder").labelStyle(.iconOnly)
                Spacer(minLength: 4)
                Button("Recognized Text", systemImage: "text.alignleft") { showTranscript.toggle() }
                    .labelStyle(.iconOnly)
                    .disabled(result.transcript.isEmpty)
                    .popover(isPresented: $showTranscript) {
                        ScrollView { Text(verbatim: result.transcript).textSelection(.enabled).padding() }
                            .frame(width: 320, height: 240)
                    }
                Button("Copy All", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.transcript, forType: .string)
                }.labelStyle(.iconOnly).disabled(result.transcript.isEmpty)
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }.padding(10).background(.bar)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .zIndex(1)
            ZStack {
                Color.black
                if let image = result.image {
                    FrameTextSurface(image: image, analysis: result.analysis)
                        .accessibilityLabel("Select text directly in the captured frame")
                }
                switch result.phase {
                case .capturing: ProgressView("Capturing frame…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                case .recognizing: ProgressView("Recognizing text…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                case .failed(let message):
                    ContentUnavailableView("Unable to Recognize Text", systemImage: "exclamationmark.bubble", description: Text(message)).foregroundStyle(.white)
                case .ready:
                    if result.transcript.isEmpty {
                        VStack { Text("No Text Found").padding(8).background(.regularMaterial, in: Capsule()); Spacer() }.padding()
                    }
                case .cancelled: EmptyView()
                }
            }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
        }
        .onExitCommand(perform: onClose)
        .accessibilityLabel(source)
    }
}
private struct FrameTextSurface: NSViewRepresentable {
    let image: NSImage
    let analysis: ImageAnalysis?
    final class ImageView: NSImageView {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        CGSize(width: max(0, proposal.width ?? 0), height: max(0, proposal.height ?? 0))
    }
    func makeNSView(context: Context) -> NSImageView {
        let view = ImageView()
        view.imageScaling = .scaleProportionallyUpOrDown; view.imageAlignment = .alignCenter; view.image = image
        let overlay = ImageAnalysisOverlayView(frame: view.bounds)
        overlay.autoresizingMask = [.width, .height]; overlay.trackingImageView = view
        overlay.preferredInteractionTypes = [.textSelection, .dataDetectors]
        view.addSubview(overlay); return view
    }
    func updateNSView(_ view: NSImageView, context: Context) {
        guard let overlay = view.subviews.first as? ImageAnalysisOverlayView else { return }
        if view.image !== image { view.image = image }
        if overlay.analysis !== analysis { overlay.analysis = analysis }
    }
    static func dismantleNSView(_ view: NSImageView, coordinator: ()) {
        for case let overlay as ImageAnalysisOverlayView in view.subviews {
            overlay.analysis = nil
            overlay.trackingImageView = nil
        }
        view.image = nil
    }
}
