import AppKit
import SwiftUI

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]); NSApp.terminate(nil); return
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task { @MainActor in AppModel.shared.prepare() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { MainActor.assumeIsolated { AppModel.shared.shutdown() } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) })?.makeKeyAndOrderFront(nil) }; return true
    }
}
@main
struct LocalVoiceMac: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    init() { if CommandLine.arguments.contains("--accessibility-probe") { if let data = try? JSONEncoder().encode(AccessibilityProbe.current()), let text = String(data: data, encoding: .utf8) { print(text) }; exit(0) }; if CommandLine.arguments.contains("--diagnose") { Diagnostics.run(); exit(0) } }
    var body: some Scene {
        Window("DAVE", id: "main") { MainView(model: model).frame(minWidth: 760, minHeight: 520) }
            .defaultSize(width: 1040, height: 740)
            .commands {
                CommandGroup(replacing: .newItem) { Button(model.section == .transcribe ? "Open Audio File…" : "Open Text File…") { if model.section == .transcribe { model.transcription.chooseFile() } else { model.openFile() } }.keyboardShortcut("o"); Button("Paste for Reading", action: model.paste).keyboardShortcut("v", modifiers: [.command, .shift]) }
            }
        Settings { PreferencesView(model: model).frame(width: 560).onAppear { model.settingsOpen = true }.onDisappear { model.settingsOpen = false } }
        MenuBarExtra("DAVE", systemImage: "waveform") {
            Button("Show DAVE") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) })?.makeKeyAndOrderFront(nil) }
            Divider()
            Button(model.speech.recording ? "Finish Dictation" : "Dictate at Cursor") { Task { await model.toggleDictation(external: true) } }
            Button("Read Selected Text", action: model.readSelection)
            Button("Stop Reading", action: model.stopReading).disabled(!model.playing)
            Divider()
            SettingsLink()
            Button("Quit DAVE") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
