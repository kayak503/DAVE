import AppKit
import SwiftUI
import AVFoundation

struct MainView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        NavigationSplitView {
            List(selection: $model.section) {
                Label("Read", systemImage: "book.closed").tag(AppModel.Section.read)
                Label("Dictate", systemImage: "mic").tag(AppModel.Section.dictate)
                Label("Transcribe", systemImage: "waveform.badge.magnifyingglass").tag(AppModel.Section.transcribe)
                Label("Models", systemImage: "cpu").tag(AppModel.Section.models)
            }.listStyle(.sidebar).navigationSplitViewColumnWidth(min: 150, ideal: 175, max: 220)
            .safeAreaInset(edge: .bottom) { HStack { SettingsLink { Label("Settings", systemImage: "gearshape") }; Spacer() }.buttonStyle(.plain).padding() }
        } detail: {
            VStack(spacing: 0) {
                switch model.section { case .read: ReaderView(model: model); case .dictate: DictationView(model: model); case .models: ModelLibraryView(model: model); case .transcribe: TranscriptionView(controller: model.transcription, modelID: model.preferences.value.transcriptionModel, device: model.preferences.value.transcriptionDevice, models: model.models, onModelChange: { id in model.updatePreferences { $0.transcriptionModel = id } }) }
            }.overlay(alignment: .top) {
                if !model.message.isEmpty { ToastView(model: model, hoverID: "main").padding(12).frame(maxWidth: 620).zIndex(10) }
            }.navigationTitle(model.section.rawValue)
            .toolbar {
                if model.section == .read {
                    ToolbarItemGroup {
                        Button(action: model.openFile) { Image(systemName: "doc.badge.plus") }.help("Open text or Markdown file").accessibilityLabel("Open text file")
                        Button(action: model.paste) { Image(systemName: "doc.on.clipboard") }.help("Paste text").accessibilityLabel("Paste text")
                    }
                    ToolbarItemGroup {
                        Button { if model.playing { model.pauseReading() } else { model.play() } } label: { Label(model.playing ? model.paused ? "Resume" : "Pause" : "Read", systemImage: model.playing && !model.paused ? "pause.fill" : "play.fill") }.disabled(model.sentences.isEmpty).accessibilityIdentifier("reader.play")
                        Button(action: model.stopReading) { Image(systemName: "stop.fill") }.disabled(!model.playing).accessibilityLabel("Stop reading")
                    }
                }
            }
        }
    }
}
struct ReaderView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Document mode", selection: $model.editing) { Text("Read").tag(false); Text("Edit").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                Spacer()
                Text("\(model.source.split(whereSeparator: { $0.isWhitespace }).count) words").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.vertical, 12)
            Divider()
            if model.editing {
                TextEditor(text: $model.source).font(.system(.body, design: .monospaced)).padding(16).accessibilityIdentifier("reader.editor")
            } else if model.source.isEmpty {
                VStack(spacing: 18) {
                    Image(systemName: "text.book.closed").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                    Text("Ready when you are").font(.title2.weight(.medium))
                    Text("Paste a passage or open a text or Markdown file.\nYour words stay on this Mac.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    HStack { Button("Paste Text", action: model.paste).buttonStyle(.borderedProminent); Button("Open File…", action: model.openFile); Button("Write Text", action: model.beginEditing) }
                    Text("Or select text in another app and press \(model.preferences.value.readShortcut.display).").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32).background(Color(nsColor: .textBackgroundColor)).onTapGesture(count: 2, perform: model.beginEditing)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(model.sentences) { sentence in
                                Text((try? AttributedString(markdown: sentence.display)) ?? AttributedString(sentence.display))
                                        .font(sentence.kind == "heading" ? .title2.weight(.semibold) : sentence.kind == "code" ? .system(.body, design: .monospaced) : .system(size: 18))
                                        .lineSpacing(6).frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(model.currentSentence == sentence.id ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                        .contentShape(Rectangle())
                                        .gesture(TapGesture(count: 2).onEnded { model.beginEditing() }.exclusively(before: TapGesture(count: 1).onEnded { model.play(from: sentence.id) }))
                                        .accessibilityAddTraits(.isButton).accessibilityAction { model.play(from: sentence.id) }
                                        .id(sentence.id).accessibilityLabel("Read sentence: \(sentence.text)").accessibilityHint("Double-click to edit text").accessibilityIdentifier("reader.sentence.\(sentence.id)")
                            }
                        }.frame(maxWidth: 760, alignment: .leading).padding(28).frame(maxWidth: .infinity)
                    }.background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: model.currentSentence) { _, value in if let value { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(value, anchor: .center) } } }
                }
            }
            if !model.source.isEmpty {
            Divider()
            GenerationView(model: model)
            HStack(spacing: 18) {
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Text(model.playing ? model.speech.status : "Ready").font(.callout).lineLimit(1)
                Spacer()
                ReadingSkipButtons(model: model)
                ReadingSpeedButton(model: model)
            }.padding(16).background(.bar)
            }
        }
    }
}
struct DictationView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 20) {
                Button { Task { await model.toggleDictation() } } label: { Image(systemName: model.speech.recording ? "stop.fill" : "mic.fill").font(.title2).frame(width: 48, height: 48) }.buttonStyle(.borderedProminent).tint(model.speech.recording ? .red : .accentColor).clipShape(Circle()).disabled(model.busy).accessibilityLabel(model.speech.recording ? "Finish dictation" : "Start dictation").accessibilityIdentifier("dictation.record")
                VStack(alignment: .leading, spacing: 5) { Text(model.speech.recording ? "Listening" : model.busy ? model.speech.status : "Speak naturally").font(.title2.weight(.medium)); Text(model.speech.recording ? "Press Enter or the microphone to finish." : "Your voice stays on this Mac.").foregroundStyle(.secondary) }
                Spacer()
                if model.speech.recording { Button("Cancel", action: model.cancelDictation) }
            }
            WaveformView(samples: model.speech.history.samples, active: model.speech.recording).frame(height: 45).accessibilityLabel("Microphone level \(Int(model.speech.level * 100)) percent")
            TextEditor(text: $model.transcript).font(.system(size: 17)).padding(10).background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.4))).accessibilityLabel("Transcript").accessibilityIdentifier("dictation.transcript")
            HStack { Button("Copy", action: model.copyTranscript).disabled(model.transcript.isEmpty); Button("Read Back") { model.source = model.transcript; model.section = .read; model.play(from: 0) }.disabled(model.transcript.isEmpty); Spacer(); Button("Suggest Wording", action: model.suggestWording).disabled(model.transcript.isEmpty || model.busy).help("Create a local suggestion; your transcript stays unchanged until you accept.") }
            if let suggestion = model.proposal {
                VStack(alignment: .leading, spacing: 12) { Text("Suggested wording").font(.headline); Text(suggestion).textSelection(.enabled); HStack { Button("Use Suggestion") { model.transcript = suggestion; model.proposal = nil }; Button("Dismiss") { model.proposal = nil } } }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
        }.padding(30)
    }
}
struct WaveformView: View {
    var samples: [Double]; var active: Bool
    var body: some View {
        GeometryReader { geometry in
            let visible = Array(samples.suffix(max(1, min(samples.count, Int(geometry.size.width / 5)))))
            HStack(alignment: .center, spacing: 4) {
                ForEach(visible.indices, id: \.self) { i in
                    Capsule().fill(active ? Color.accentColor.opacity(0.35 + 0.65 * Double(i + 1) / Double(visible.count)) : Color.secondary.opacity(0.25))
                        .frame(width: max(1, (geometry.size.width - CGFloat(visible.count - 1) * 4) / CGFloat(visible.count)), height: max(3, CGFloat(visible[i]) * geometry.size.height))
                }
            }.frame(height: geometry.size.height).animation(.linear(duration: 0.05), value: samples)
        }.accessibilityLabel("Microphone history, newest sound on the right")
    }
}

struct GenerationView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.playing {
            VStack(alignment: .leading, spacing: 6) {
                if model.waitingForAudio {
                    HStack {
                        ProgressView().controlSize(.small)
                        TimelineView(.periodic(from: .now, by: 0.2)) { context in
                            Text("Generating sentence \((model.currentSentence ?? 0) + 1) of \(model.sentences.count) · \(max(0, context.date.timeIntervalSince(model.readerGenerator.preparationStarted ?? context.date)), specifier: "%.1f")s").monospacedDigit()
                        }
                    }
                }
                Text("\(max(0, model.bufferedSentences - (model.waitingForAudio ? 0 : 1))) sentences ready ahead · target \(model.preferences.value.generateAhead)").foregroundStyle(.secondary)
                if let timing = model.speech.timing, model.speech.timingModel == model.preferences.value.ttsModel {
                    Text("Last sentence: \(timing.audioDuration, specifier: "%.1f")s of audio generated in \(timing.preparation, specifier: "%.1f")s · generation capacity ≈\(timing.capacity, specifier: "%.1f")×").foregroundStyle(.secondary)
                    if timing.isSlower(than: model.preferences.value.rate) {
                        Label("Generation is slower than your \(model.preferences.value.rate, specifier: "%.1f")× playback. Try Mac System Voice or a lighter model to reduce waits.", systemImage: "speedometer").foregroundStyle(.orange)
                    } else { Text("Preparing upcoming sentences while you listen.").foregroundStyle(.tertiary) }
                } else { Text("Measuring this voice on your Mac…").foregroundStyle(.secondary) }
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 10).background(.bar)
        }
    }
}

struct ToastView: View {
    @ObservedObject var model: AppModel
    var hoverID: String
    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.error ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(model.error ? Color.orange : Color.accentColor)
                Text(model.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: model.dismissToast) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss notification")
            }
            GeometryReader { proxy in
                Capsule().fill(.secondary.opacity(0.15))
                Capsule().fill(Color.accentColor).frame(width: proxy.size.width * model.toast.fraction)
            }.frame(height: 2)
        }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.3))).shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .onHover { model.hoverToast(hoverID, hovering: $0) }.onDisappear { model.hoverToast(hoverID, hovering: false) }
        .accessibilityLabel(model.message).accessibilityHint("Disappears automatically; hover to pause")
    }
}
struct ModelLibraryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Reading") {
                    HStack { VStack(alignment: .leading) { Text("Mac System Voice"); Text("Built in · no download required").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary) }
                    ForEach(model.models.filter { $0.task == "tts" }) { row($0) }
                }
                Section("Dictation & transcription") { ForEach(model.models.filter { $0.task == "stt" && $0.variantOf == nil }) { row($0) } }
                Section("Optional wording") { ForEach(model.models.filter { $0.task == "rewrite" }) { row($0) } }
            }
            HStack { if model.busy { ProgressView().controlSize(.small) }; Text(model.busy ? model.speech.status : "Downloads are optional. Installed models run offline.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Refresh") { Task { await model.refreshModels() } }.disabled(model.busy) }.padding()
        }.task { if model.models.isEmpty { await model.refreshModels() } }
    }
    func row(_ item: LocalModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) { Text(item.name); Text("\(item.tier) · \(Int(item.sizeMB)) MB").font(.caption).foregroundStyle(.secondary)
                if let detail = item.description { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if item.task == "stt", TranscriptionModelGuidance.recommendedForGroups(item.id) {
                    Text("Recommended tier for multi-person transcripts").font(.caption).foregroundStyle(Color.accentColor)
                }
            }
            Spacer()
            if item.installed { Text("Installed").foregroundStyle(.secondary).font(.caption); Button("Remove") { model.removeModel(item.id) }.disabled(model.busy || model.playing || model.speech.recording) }
            else { Button("Download") { model.installModel(item.id) }.disabled(model.busy) }
        }.padding(.vertical, 7)
    }
}
struct PreferencesView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("Voices") {
                Picker("Voice model", selection: Binding(get: { model.preferences.value.ttsModel }, set: { value in model.updatePreferences { $0.ttsModel = value } })) { Text("Mac System Voice").tag("system"); ForEach(model.models.filter { $0.task == "tts" && $0.installed }) { Text($0.name).tag($0.id) } }
                ForEach(model.availableVoices) { voice in
                    HStack {
                        Button { model.selectVoice(voice.id) } label: {
                            Label(voice.name, systemImage: model.selectedVoiceID == voice.id ? "checkmark.circle.fill" : "circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityLabel("Use " + voice.name)
                        Button { model.previewVoice(voice.id) } label: {
                            Label(model.previewVoiceID == voice.id ? (model.voicePreview.preparing ? "Preparing…" : "Stop") : "Sample",
                                  systemImage: model.previewVoiceID == voice.id ? "stop.fill" : "play.fill")
                        }.disabled(model.speech.recording || model.busy).accessibilityLabel((model.previewVoiceID == voice.id ? "Stop sample for " : "Play sample for ") + voice.name)
                    }
                }
                Text("Preview at normal speed, then click a voice to use it for reading. Samples play entirely on this Mac. Download additional reading models in Models to try more voices.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Reading & dictation") {
                Picker("Dictation model", selection: Binding(get: { model.preferences.value.sttModel }, set: { value in model.updatePreferences { $0.sttModel = value } })) { ForEach(model.models.filter { $0.task == "stt" && $0.variantOf == nil }) { Text($0.name + (recognitionReady(model.models, id: $0.id, device: model.preferences.value.dictationDevice) ? "" : " — download needed")).tag($0.id) } }
                Stepper("Generate ahead: \(model.preferences.value.generateAhead) sentences", value: Binding(get: { model.preferences.value.generateAhead }, set: { value in model.updatePreferences { $0.generateAhead = value } }), in: 3...10)
                Text("Prepares upcoming sentences while reading. More sentences use more temporary disk space and make forward skipping quicker.").font(.caption).foregroundStyle(.secondary)
                Toggle("Read code blocks aloud", isOn: Binding(get: { model.preferences.value.readCode }, set: { value in model.updatePreferences { $0.readCode = value } }))
            }
            Section("Transcription") {
                Picker("Audio-file model", selection: Binding(get: { model.preferences.value.transcriptionModel }, set: { value in model.updatePreferences { $0.transcriptionModel = value } })) {
                    ForEach(model.models.filter { $0.task == "stt" && $0.variantOf == nil }) { Text($0.name + (recognitionReady(model.models, id: $0.id, device: model.preferences.value.transcriptionDevice) ? "" : " — download needed")).tag($0.id) }
                }.disabled(model.transcription.running)
                Text("Independent of the dictation model. For recordings with multiple people, start with Whisper Small or above and enable Distinguish speakers in Transcribe.").font(.caption).foregroundStyle(.secondary)
                Text(TranscriptionModelGuidance.detail(model.preferences.value.transcriptionModel)).font(.caption).foregroundStyle(.secondary)
            }
            Section("Acceleration") {
                AccelerationSettings(model: model)
            }
            Section("Global shortcuts") {
                LabeledContent("Read selected text") { ShortcutRecorder(shortcut: model.preferences.value.readShortcut, onChange: { value in model.updatePreferences { $0.readShortcut = value } }, onError: { model.report($0) }).frame(width: 200, height: 30) }
                LabeledContent("Start / finish dictation") { ShortcutRecorder(shortcut: model.preferences.value.dictateShortcut, onChange: { value in model.updatePreferences { $0.dictateShortcut = value } }, onError: { model.report($0) }).frame(width: 200, height: 30) }
                Text("Click a shortcut and press a modifier plus a letter. Left and right keys are supported. Escape cancels.").font(.caption).foregroundStyle(.secondary)
                Picker("Compact controls", selection: Binding(get: { model.preferences.value.overlayTop }, set: { value in model.updatePreferences { $0.overlayTop = value } })) { Text("Bottom of screen").tag(false); Text("Top of screen").tag(true) }
            }
            Section("Permissions") {
                Label(model.accessibilityReady ? "Accessibility enabled" : "Accessibility required for other apps", systemImage: model.accessibilityReady ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(model.accessibilityReady ? Color.secondary : Color.orange)
                HStack { Button("Open Accessibility Settings") { model.accessibility.request(); model.accessibility.openSettings() }; Button("Reveal This App") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) } }
                Text("Grant access to this app: \(Bundle.main.bundleURL.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Label(model.microphonePermission == .authorized ? "Microphone enabled" : model.microphonePermission == .notDetermined ? "Microphone access is requested when recording starts" : "Microphone access is blocked", systemImage: model.microphonePermission == .authorized ? "checkmark.circle" : "mic").foregroundStyle(.secondary)
                if model.microphonePermission == .denied || model.microphonePermission == .restricted { Button("Open Microphone Settings") { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) } } }
                Button(model.verifyingAccessibility ? "Verifying…" : "Verify Accessibility") { Task { await model.verifyAccessibility() } }.disabled(model.verifyingAccessibility)
                if !model.accessibilityVerification.isEmpty { Text(model.accessibilityVerification).font(.caption).textSelection(.enabled) }
            }
            HStack { Text(model.preferencesStatus).foregroundStyle(model.preferences.error == nil ? Color.secondary : Color.red); Spacer(); Text("Local Voice · Native Mac").foregroundStyle(.tertiary) }.font(.caption)
        }.formStyle(.grouped).padding(.vertical, 10).onDisappear { model.stopVoicePreview() }
    }
}

struct ReadingSpeedButton: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Button {
            model.updatePreferences { $0.rate = ReadingControls.nextSpeed($0.rate) }
        } label: {
            Text("Speed \(model.preferences.value.rate, specifier: "%g")×").monospacedDigit()
        }.fixedSize()
            .help("Click to cycle speed: 0.5×, 1×, 1.2×, 1.5×, 2×")
            .accessibilityLabel("Playback speed").accessibilityValue(String(format: "%g times", model.preferences.value.rate))
    }
}

struct ReadingSkipButtons: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Button { model.skipSentence(-1) } label: { Image(systemName: "backward.end.fill") }
            .disabled((model.currentSentence ?? 0) <= 0)
            .help("Previous sentence (Left arrow)").accessibilityLabel("Previous sentence")
        Button { model.skipSentence(1) } label: { Image(systemName: "forward.end.fill") }
            .disabled((model.currentSentence ?? 0) >= model.sentences.count - 1)
            .help("Next sentence (Right arrow)").accessibilityLabel("Next sentence")
    }
}
