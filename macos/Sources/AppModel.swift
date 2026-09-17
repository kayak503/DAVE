import AppKit
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    enum Section: String, CaseIterable { case read = "Read", dictate = "Dictate", transcribe = "Transcribe", models = "Models" }
    @Published var section: Section = .read
    @Published var source = "" { didSet { if source != oldValue { stopReading(); sentences = DocumentParser.sentences(source, readCode: preferences.value.readCode) } } }
    @Published var sentences: [SpokenSentence] = []
    @Published var currentSentence: Int? = nil
    @Published var playing = false
    @Published var paused = false
    @Published var editing = false
    var settingsOpen = false
    @Published var transcript = "" { didSet { if transcript != oldValue { proposal = nil } } }
    @Published var proposal: String? = nil
    @Published var message = ""
    @Published var error = false
    @Published var toast = ToastCountdown()
    private var toastHover = Set<String>()
    private var toastTimer: Timer?
    private var enterMonitor: Any?
    private var capturedTarget = false
    @Published var busy = false
    @Published var models: [LocalModel] = []
    @Published var accessibilityReady = false
    @Published var verifyingAccessibility = false
    @Published var accessibilityVerification = ""
    @Published var microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var preferencesStatus = "Changes save automatically"
    let preferences: PreferencesStore
    let speech = LocalSpeech()
    let readerGenerator = LocalSpeech()
    let voicePreview = LocalSpeech()
    @Published var previewVoiceID: String?
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = UUID()
    var availableVoices: [ReadingVoice] {
        if preferences.value.ttsModel == "system" {
            return [ReadingVoice(id: "", name: "Mac default")] + AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language.hasPrefix("en") }
                .sorted { $0.name < $1.name }
                .map { ReadingVoice(id: $0.identifier, name: "\($0.name) · \($0.language)") }
        }
        return models.first { $0.id == preferences.value.ttsModel }?.voices ?? []
    }
    var selectedVoiceID: String {
        let prefs = preferences.value
        if prefs.ttsModel == "system" { return prefs.systemVoice }
        let saved = prefs.readingVoices[prefs.ttsModel] ?? prefs.voice
        return availableVoices.contains(where: { $0.id == saved }) ? saved : (availableVoices.first?.id ?? saved)
    }
    func selectVoice(_ id: String) {
        stopVoicePreview()
        updatePreferences { if $0.ttsModel == "system" { $0.systemVoice = id } else { $0.voice = id; $0.readingVoices[$0.ttsModel] = id } }
    }
    func previewVoice(_ id: String) {
        if previewVoiceID == id { stopVoicePreview(); return }
        guard !speech.recording, !busy else { report("Finish dictating before previewing a voice."); return }
        stopVoicePreview(); stopReading(); previewVoiceID = id
        let token = UUID(); previewGeneration = token
        let model = preferences.value.ttsModel
        previewTask = Task {
            do { try await voicePreview.speak("Hello! This is a sample of my voice. I can read your notes, stories, and documents, right here on your Mac.", model: model, voice: id, rate: 1) }
            catch { if token == previewGeneration && !Task.isCancelled { report(error.localizedDescription) } }
            if token == previewGeneration { previewVoiceID = nil; previewTask = nil }
        }
    }
    func stopVoicePreview() {
        previewGeneration = UUID(); previewTask?.cancel(); previewTask = nil
        voicePreview.stopSpeaking(); previewVoiceID = nil
    }
    private var readingBuffer: ReadingBuffer<LocalSpeech.PreparedSpeech>?
    @Published var bufferedSentences = 0
    @Published var waitingForAudio = false
    let accessibility = MacAccessibility()
    let hotkeys = GlobalHotkeys()
    private var observers = Set<AnyCancellable>()
    private var readingTask: Task<Void, Never>?
    private var generation = UUID()
    private var externalDictation = false
    private var started = false
    private var lastShortcutPair: [Shortcut] = []
    private var lastShortcutError = ""
    private var permissionTimer: Timer?
    lazy var transcription = TranscriptionController(speech: LocalSpeech(), speakerModelID: preferences.value.speakerModel, onSpeakerModelChange: { [weak self] id in self?.updatePreferences { $0.speakerModel = id } })
    lazy var compact = CompactController(model: self)

    init(preferencesURL: URL? = nil) {
        preferences = PreferencesStore(url: preferencesURL)
        preferences.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        voicePreview.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        readerGenerator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        transcription.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        speech.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        speech.$recording.sink { [weak self] recording in self?.hotkeys.dictating = recording }.store(in: &observers)
        hotkeys.onFinish = { [weak self] in guard let self, self.speech.recording else { return }; Task { await self.toggleDictation() } }
        hotkeys.onRead = { [weak self] in self?.readSelection() }
        hotkeys.onDictate = { [weak self] in guard let self else { return }; Task { await self.toggleDictation(external: true) } }
    }
    func prepare() {
        guard !started else { return }; started = true
        if let failure = preferences.error { report(failure) }
        checkPermissions()
        enterMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                let textEditor = (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable == true
                if self.section == .read, self.playing, !self.editing, !textEditor,
                   !GlobalHotkeys.capturing, !self.settingsOpen,
                   event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                   event.keyCode == 123 || event.keyCode == 124 {
                    self.skipSentence(event.keyCode == 123 ? -1 : 1); return true
                }
                guard DictationDeliveryPolicy.isFinishKey(event.keyCode, modifiers: UInt64(event.modifierFlags.rawValue), recording: self.speech.recording, capturingShortcut: GlobalHotkeys.capturing) else { return false }
                if !event.isARepeat { Task { await self.toggleDictation() } }
                return true
            }
            return consumed ? nil : event
        }
        toastTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in Task { @MainActor in self?.advanceToast() } }
        Task { await refreshModels() }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkPermissions() } }
    }
    func report(_ text: String, failure: Bool = true) {
        message = text; error = failure
        toast.start(seconds: failure ? 8 : 5, now: ProcessInfo.processInfo.systemUptime)
        if !NSApp.isActive { compact.showNotice() }
    }
    func hoverToast(_ id: String, hovering: Bool) {
        advanceToast()
        if hovering { toastHover.insert(id) } else { toastHover.remove(id) }
    }
    func advanceToast() {
        guard !message.isEmpty else { return }
        toast.tick(now: ProcessInfo.processInfo.systemUptime, paused: !toastHover.isEmpty)
        if toast.remaining == 0 { dismissToast() }
    }
    func dismissToast() { message = ""; error = false; toastHover.removeAll(); compact.hideNotice() }
    func beginEditing() { stopReading(); editing = true }
    func checkPermissions() {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphonePermission != microphone { microphonePermission = microphone }
        let granted = accessibility.trusted
        if granted != accessibilityReady { accessibilityReady = granted; lastShortcutPair = [] }
        if !granted { hotkeys.stop(); lastShortcutError = ""; return }
        guard !GlobalHotkeys.capturing else { return }
        let pair = [preferences.value.readShortcut, preferences.value.dictateShortcut]
        guard pair != lastShortcutPair || !hotkeys.isActive else { return }
        do { try hotkeys.apply(read: pair[0], dictate: pair[1]); lastShortcutPair = pair; lastShortcutError = "" }
        catch { if lastShortcutError != error.localizedDescription { lastShortcutError = error.localizedDescription; report(error.localizedDescription) } }
    }
    func verifyAccessibility() async {
        guard !verifyingAccessibility else { return }
        verifyingAccessibility = true
        defer { verifyingAccessibility = false }
        let fresh = if let executable = Bundle.main.executableURL { await AccessibilityProbe.freshProcess(executable: executable) } else { nil as AccessibilityProbe? }
        hotkeys.stop(); lastShortcutPair = []; lastShortcutError = ""
        checkPermissions()
        accessibilityVerification = AccessibilityProbe.current().explanation(fresh: fresh, shortcutsActive: hotkeys.isActive)
        if fresh == nil { accessibilityVerification += " Fresh-process comparison was unavailable." }
    }
    func updatePreferences(_ change: (inout VoicePreferences) -> Void) {
        do {
            let before = preferences.value
            try preferences.update(change)
            preferencesStatus = "Saved"
            speech.setRate(preferences.value.rate)
            if before.readCode != preferences.value.readCode { stopReading(); sentences = DocumentParser.sentences(source, readCode: preferences.value.readCode) }
            if before.ttsModel != preferences.value.ttsModel || before.voice != preferences.value.voice || before.systemVoice != preferences.value.systemVoice || before.readingVoices != preferences.value.readingVoices { stopReading(); stopVoicePreview() }
            if playing, before.generateAhead != preferences.value.generateAhead {
                readingBuffer?.fill(from: currentSentence ?? 0, count: sentences.count, ahead: preferences.value.generateAhead)
            }
            checkPermissions()
        } catch { preferencesStatus = "Couldn’t save"; report(error.localizedDescription) }
    }
    func refreshModels() async {
        do { models = try await speech.models() }
        catch { report(error.localizedDescription) }
    }
    func installModel(_ id: String) { guard !busy else { return }; busy = true; Task {
        defer { busy = false }
        do { try await speech.install(id); await refreshModels(); report("Model ready for offline use.", failure: false) }
        catch { report(error.localizedDescription) }
    } }
    func removeModel(_ id: String) { guard !busy, !playing, !speech.recording else { return }; busy = true; Task {
        defer { busy = false }
        do { try await speech.remove(id); await refreshModels() } catch { report(error.localizedDescription) }
    } }
    func paste() { if let text = NSPasteboard.general.string(forType: .string) { source = text; section = .read } }
    func openFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.text, .sourceCode, .json] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { let attributes = try FileManager.default.attributesOfItem(atPath: url.path); if (attributes[.size] as? NSNumber)?.intValue ?? 0 > 2_000_000 { throw NSError(domain: "LocalVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Open a text file smaller than 2 MB."]) }; self?.source = try String(contentsOf: url, encoding: .utf8); self?.section = .read }
                catch { self?.report(error.localizedDescription) }
            }
        }
    }
    func play(from index: Int? = nil) {
        if speech.recording { report("Finish dictating before starting playback."); return }
        stopVoicePreview()
        if playing && paused && index == nil { paused = false; speech.resume(); return }
        generation = UUID(); readingTask?.cancel(); speech.stopSpeaking()
        guard !sentences.isEmpty else { return }
        let start = max(0, min(index ?? currentSentence ?? 0, sentences.count - 1))
        let token = UUID(); generation = token; playing = true; paused = false; dismissToast()
        let items = sentences
        if readingBuffer == nil {
            let voice = selectedVoiceID, model = preferences.value.ttsModel
            readingBuffer = ReadingBuffer(prepare: { [readerGenerator] i in
                try await readerGenerator.prepareSpeech(items[i].text, model: model, voice: voice)
            }, dispose: { $0.dispose() })
            readingBuffer?.onChange = { [weak self] in
                guard let self else { return }
                self.bufferedSentences = self.readingBuffer?.readyCount ?? 0
            }
        }
        guard let buffer = readingBuffer else { return }
        readingTask = Task { [weak self] in
            guard let self else { return }
            for i in start..<items.count {
                guard generation == token, !Task.isCancelled else { return }
                currentSentence = i
                do {
                    waitingForAudio = true
                    buffer.fill(from: i, count: items.count, ahead: preferences.value.generateAhead)
                    let prepared = try await buffer.value(at: i)
                    guard generation == token, !Task.isCancelled else { return }
                    waitingForAudio = false
                    try await speech.playPrepared(prepared, rate: preferences.value.rate, paused: paused)
                }
                catch { if generation == token, !Task.isCancelled { stopReading(); compact.hide(); report(error.localizedDescription) }; return }
            }
            if generation == token { stopReading(); currentSentence = nil; compact.hide() }
        }
    }
    func pauseReading() { guard playing else { return }; if paused { speech.resume() } else { speech.pause() }; paused.toggle() }
    func skipSentence(_ delta: Int) {
        let next = (currentSentence ?? 0) + delta
        guard sentences.indices.contains(next) else { return }
        play(from: next)
    }
    func stopReading() {
        generation = UUID(); readingTask?.cancel(); readingTask = nil; speech.stopSpeaking()
        readingBuffer?.cancel(); readingBuffer = nil; readerGenerator.stopSpeaking()
        bufferedSentences = 0; waitingForAudio = false; playing = false; paused = false
    }
    func readSelection() {
        guard accessibility.trusted else { report("Allow Accessibility for DAVE to read selections in other apps."); return }
        guard !busy, !speech.recording else { report("Finish dictating before reading a selection."); return }
        busy = true
        Task {
            defer { busy = false }
            do { let text = try await accessibility.selectedTextWithCopyFallback(); source = text; currentSentence = 0; play(from: 0); compact.show() }
            catch { report("Read: " + error.localizedDescription) }
        }
    }
    func toggleDictation(external: Bool = false) async {
        guard !busy else { return }
        if speech.recording {
            busy = true
            defer { busy = false; externalDictation = false; capturedTarget = false; accessibility.clearTarget() }
            do {
                let text = try await speech.finishRecording(model: preferences.value.sttModel, device: preferences.value.dictationDevice)
                transcript = text; proposal = nil
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { compact.hide(); report("No speech detected. Try again closer to the microphone."); return }
                let delivery = DictationDelivery.deliver(text,
                    shouldInsert: DictationDeliveryPolicy.shouldInsert(external: externalDictation, capturedTarget: capturedTarget),
                    copy: { value in
                        NSPasteboard.general.clearContents()
                        return NSPasteboard.general.setString(value, forType: .string)
                    }, insert: { try accessibility.insert($0) })
                compact.hide()
                report(delivery.message, failure: !delivery.copied)
            } catch { compact.hide(); report(error.localizedDescription) }
        } else {
            stopVoicePreview(); stopReading(); dismissToast(); busy = true
            defer { busy = false }
            do {
                guard recognitionReady(models, id: preferences.value.sttModel, device: preferences.value.dictationDevice) else { throw PreferenceError(message: preferences.value.dictationDevice == "metal" ? "Download GPU files for your dictation model in Settings → Acceleration." : "Download your dictation model in Models, or its GPU files in Settings → Acceleration, before recording.") }
                capturedTarget = false
                if external {
                    do { try accessibility.captureTarget(); capturedTarget = true }
                    catch { accessibility.clearTarget() }
                }
                try await speech.startRecording(); externalDictation = external
                if external { compact.show() }
            } catch { accessibility.clearTarget(); capturedTarget = false; externalDictation = false; compact.hide(); report(error.localizedDescription) }
        }
    }
    func cancelDictation() { speech.cancelRecording(); externalDictation = false; capturedTarget = false; accessibility.clearTarget(); compact.hide(); report("Recording cancelled.", failure: false) }
    func copyTranscript() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(transcript, forType: .string); report("Copied.", failure: false) }
    func suggestWording() { guard !busy, !transcript.isEmpty else { return }; let original = transcript; busy = true; Task {
        defer { busy = false }
        do { let text = try await speech.rewrite(original); if transcript == original { proposal = text } else { report("Text changed. Request a new suggestion.", failure: false) } }
        catch { report(error.localizedDescription) }
    } }
    func shutdown() {
        stopVoicePreview(); voicePreview.shutdown(); transcription.shutdown(); toastTimer?.invalidate(); if let enterMonitor { NSEvent.removeMonitor(enterMonitor) }; compact.hideNotice(); permissionTimer?.invalidate(); hotkeys.stop(); stopReading(); speech.cancelRecording(); speech.shutdown(); readerGenerator.shutdown(); compact.hide() }
}
