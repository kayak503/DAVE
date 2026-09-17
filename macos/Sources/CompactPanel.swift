import AppKit
import SwiftUI

@MainActor final class NonactivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class CompactController {
    private let model: AppModel
    private var panel: NSPanel?
    private var notice: NSPanel?
    init(model: AppModel) { self.model = model }
    func show() {
        if panel == nil {
            let value = NonactivatingPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 105), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            value.level = .floating; value.isFloatingPanel = true; value.hidesOnDeactivate = false; value.isOpaque = false; value.backgroundColor = .clear; value.hasShadow = true
            value.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; value.isMovableByWindowBackground = true
            value.contentView = NSHostingView(rootView: CompactView(model: model)); panel = value
        }
        guard let panel else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main
        if let rect = screen?.visibleFrame { panel.setFrameOrigin(NSPoint(x: rect.midX - 230, y: model.preferences.value.overlayTop ? rect.maxY - 125 : rect.minY + 20)) }
        panel.orderFrontRegardless()
    }
    func showNotice() {
        if notice == nil {
            let value = NonactivatingPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            value.level = .floating; value.hidesOnDeactivate = false; value.isOpaque = false; value.backgroundColor = .clear
            value.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            value.contentView = NSHostingView(rootView: ToastView(model: model, hoverID: "floating").padding(10).frame(width: 520))
            notice = value
        }
        if let rect = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            notice?.setFrameOrigin(NSPoint(x: rect.midX - 260, y: rect.maxY - 140))
        }
        notice?.orderFrontRegardless()
    }
    func hideNotice() { notice?.orderOut(nil) }
    func showIfVisible() { if panel?.isVisible == true { show() } }
    func hide() { panel?.orderOut(nil) }
}
struct CompactView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: model.speech.recording ? "mic.fill" : model.error ? "exclamationmark.circle" : "speaker.wave.2.fill").font(.title2)
            VStack(alignment: .leading, spacing: 7) {
                Text(model.speech.recording ? "Listening" : model.busy ? model.speech.status : model.playing ? model.paused ? "Paused" : model.waitingForAudio ? "Generating speech…" : "Reading" : model.message).font(.callout.weight(.medium)).lineLimit(2)
                if model.speech.recording { WaveformView(samples: model.speech.history.samples, active: true).frame(height: 22) }
                else if model.playing {
                    HStack(spacing: 10) {
                        ReadingSpeedButton(model: model)
                        if let timing = model.speech.timing,
                           model.speech.timingModel == model.preferences.value.ttsModel,
                           timing.isSlower(than: model.preferences.value.rate) {
                            Label("May pause", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .help("This voice generates audio slower than the selected speed. Choose a lighter model or lower the speed to reduce waits.")
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if model.speech.recording { Button { Task { await model.toggleDictation() } } label: { Image(systemName: "stop.fill") }.accessibilityLabel("Finish dictation") }
            else if model.playing { ReadingSkipButtons(model: model); Button(action: model.pauseReading) { Image(systemName: model.paused ? "play.fill" : "pause.fill") }.accessibilityLabel(model.paused ? "Resume reading" : "Pause reading") }
            Button { if model.speech.recording { model.cancelDictation() }; model.stopReading(); model.compact.hide() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close compact controls")
        }.buttonStyle(.plain).padding(20).frame(width: 460, height: 105).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24)).overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.15)))
    }
}
