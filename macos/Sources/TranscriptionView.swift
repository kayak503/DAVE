import SwiftUI

struct TranscriptionView: View {
    @ObservedObject var controller: TranscriptionController
    let modelID: String
    var device: String = "auto"
    var models: [LocalModel] = []
    var onModelChange: ((String) -> Void)? = nil
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.badge.mic").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.fileURL?.lastPathComponent ?? "Transcribe audio").font(.headline).lineLimit(1)
                    Text("\(models.first(where: { $0.id == modelID })?.name ?? modelID.replacingOccurrences(of: "-", with: " ").capitalized) · Audio stays on this Mac").font(.caption).foregroundStyle(.secondary).help("Captions use the model’s phrase timestamps; individual word timing may vary.")
                }
                Spacer()
                Button("Open Audio…", action: controller.chooseFile).disabled(controller.running)
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let onModelChange {
                    Picker("Transcription model", selection: Binding(get: { modelID }, set: onModelChange)) {
                        ForEach(models.filter { $0.task == "stt" && $0.variantOf == nil }) { model in
                            Text(model.name + (recognitionReady(models, id: model.id, device: device) ? "" : " — download needed")).tag(model.id)
                        }
                    }.disabled(controller.running)
                }
                if !controller.accelerationStatus.isEmpty { Text(controller.accelerationStatus).font(.caption).foregroundStyle(.secondary) }
                Text(TranscriptionModelGuidance.detail(modelID)).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Toggle("Distinguish speakers", isOn: $controller.separateSpeakers).toggleStyle(.switch).disabled(controller.running || controller.installingSpeakers)
                    Spacer()
                    if controller.separateSpeakers {
                        Picker("Voices", selection: $controller.expectedSpeakers) {
                            Text("Automatic").tag(0)
                            ForEach(2...8, id: \.self) { Text("\($0) people (maximum)").tag($0) }
                        }.frame(width: 205).disabled(controller.running)
                    }
                }
                if controller.separateSpeakers {
                    Picker("Speaker identification", selection: Binding(get: { controller.speakerModelID }, set: controller.selectSpeakerModel)) {
                        ForEach(controller.speakerModels) { model in Text(model.name).tag(model.id) }
                    }.disabled(controller.running || controller.installingSpeakers)
                    if let model = controller.selectedSpeakerModel { Text(model.description).font(.caption).foregroundStyle(.secondary) }
                }
                if controller.separateSpeakers && !controller.speakerModelInstalled {
                    HStack {
                        Text("Download the \(Int(controller.selectedSpeakerModel?.sizeMB ?? 33)) MB speaker identification pack. This is independent of Whisper size.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if controller.installingSpeakers { ProgressView().controlSize(.small) }
                        Button(controller.installingSpeakers ? "Downloading…" : "Download Speaker Model", action: controller.installSpeakerModel).disabled(controller.installingSpeakers)
                    }
                }
                if controller.separateSpeakers {
                    if !TranscriptionModelGuidance.recommendedForGroups(modelID) {
                        Label("For multiple people, Whisper Small or above is recommended for recognizing the words.", systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                    }
                    Text("For a regular group, set the number of people and try the larger speaker identification model. Name each speaker using a clear passage, then correct individual mistakes. Speaker labels are estimates. Overlapping speech and similar voices can be difficult to separate.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            if controller.fileURL == nil {
                if !controller.status.isEmpty { Text(controller.status).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 12) }
                VStack(spacing: 16) {
                    Image(systemName: "waveform").font(.system(size: 46, weight: .light)).foregroundStyle(.secondary)
                    Text("Turn a recording into a transcript").font(.title2.weight(.medium))
                    Text("Open an audio file. Long recordings are processed\nin small sections, with captions appearing as they finish.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Choose Audio File…", action: controller.chooseFile).buttonStyle(.borderedProminent)
                    Text("WAV, MP3, M4A, AIFF and other formats supported by macOS").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else if controller.segments.isEmpty {
                VStack(spacing: 14) {
                    if controller.running { ProgressView() } else { Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(.secondary) }
                    Text(controller.running ? "Listening to your recording…" : "Ready to transcribe").font(.title3)
                    Text(controller.running ? "The first captions will appear here shortly." : "Choose whether to distinguish voices, then start.\nYou can listen to the original recording at any time.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(controller.segments) { segment in
                                HStack(alignment: .top, spacing: 16) {
                                    Text(shortTime(segment.start)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 65, alignment: .leading).padding(.top, 4)
                                    VStack(alignment: .leading, spacing: 4) {
                                        SpeakerNameButton(controller: controller, segment: segment)
                                        Button { controller.playCaption(segment) } label: {
                                            Text(segment.text).font(.system(size: 17)).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                        }.buttonStyle(.plain).accessibilityLabel("Play from \(shortTime(segment.start)): \(segment.text)")
                                    }
                                }.padding(12).background(controller.activeCaption == segment.id ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 10)).id(segment.id)
                            }
                        }.padding(20)
                    }.onChange(of: controller.activeCaption) { _, id in if controller.playing, let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
                }
            }
            if controller.fileURL != nil {
                Divider()
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Button(action: controller.togglePlayback) { Image(systemName: controller.playing ? "pause.fill" : "play.fill") }.accessibilityLabel(controller.playing ? "Pause recording" : "Play recording")
                        Text(shortTime(controller.playbackTime)).monospacedDigit().font(.caption)
                        Slider(value: Binding(get: { controller.playbackTime }, set: { controller.seek($0) }), in: 0...max(0.1, controller.duration)).accessibilityLabel("Recording position")
                        Text(shortTime(controller.duration)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
                        Menu {
                            ForEach([Float(0.5), 1, 1.2, 1.5, 2], id: \.self) { rate in Button("\(rate.formatted())×") { controller.rate = rate } }
                        } label: { Text("Speed \(controller.rate.formatted())×").monospacedDigit() }.fixedSize()
                    }
                    if controller.running { ProgressView(value: controller.progress).tint(.accentColor) }
                    HStack {
                        Text(controller.status).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                        Spacer()
                        if !controller.segments.isEmpty {
                            if controller.canUndoSpeakerEdit { Button("Undo Speaker Edit", action: controller.undoSpeakerEdit) }
                            Button("Copy", action: controller.copy)
                            Menu("Export") { ForEach(TranscriptFormat.allCases, id: \.self) { format in Button(format == .txt ? "Plain Text (.txt)" : format == .srt ? "SubRip Captions (.srt)" : "WebVTT Captions (.vtt)") { controller.export(format) } } }
                        }
                        if controller.running { Button("Stop", action: controller.cancel) }
                        else { Button(controller.segments.isEmpty ? "Transcribe" : "Transcribe Again") { controller.start(modelID: modelID, device: device) }.buttonStyle(.borderedProminent).disabled(controller.installingSpeakers || (controller.separateSpeakers && !controller.speakerModelInstalled)) }
                    }
                }.padding(18)
            }
        }.background(Color(nsColor: .textBackgroundColor)).onAppear(perform: controller.refreshSpeakerModel)
    }
    private func shortTime(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
}


struct SpeakerNameButton: View {
    @ObservedObject var controller: TranscriptionController
    let segment: TranscriptSegment
    @State private var editing = false
    @State private var name = ""
    @State private var allCaptions = false
    @State private var target = ""
    private var currentName: String { segment.speaker.map(controller.speakerName) ?? "Unknown speaker" }
    var body: some View {
        Button {
            editing = true
        } label: {
            Label(currentName + (segment.speakerConfirmed == true ? " · Confirmed" : segment.speakerReclassified == true ? " · Updated" : ""), systemImage: "pencil")
                .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
        }.buttonStyle(.plain).help("Name a speaker or correct who spoke this passage")
            .accessibilityLabel("Edit speaker for passage: \(currentName)")
            .popover(isPresented: $editing) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(allCaptions ? "Name this speaker" : "Who spoke this passage?").font(.headline)
                    Button("Listen to This Passage") { controller.playCaption(segment) }
                    if allCaptions {
                        TextField("Speaker name", text: $name).onSubmit(save)
                        Text("Names every caption assigned to this speaker. This passage becomes a confirmed example of their voice.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Speaker", selection: $target) {
                            ForEach(controller.speakerIDs, id: \.self) { id in Text(controller.speakerName(id)).tag(id) }
                            Text("New person…").tag("")
                        }
                        .onChange(of: target) { _, value in if value.isEmpty { name = "" } }
                        if target.isEmpty { TextField("New person's name", text: $name).onSubmit(save) }
                        Text("Corrects this passage, not every \(currentName) caption. Clear voice examples help reassess other passages; confirmed choices stay protected. Undo is available.").font(.caption).foregroundStyle(.secondary)
                    }
                    if segment.speakerEmbedding == nil {
                        Text("This passage has no usable voice example (it may be too short or overlapping). Its label can still be corrected.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let id = segment.speaker, !id.contains(" + ") {
                        Button(allCaptions ? "Correct Only This Passage Instead" : "Rename This Speaker Everywhere…") {
                            allCaptions.toggle(); name = controller.speakerName(id)
                        }.font(.caption)
                    }
                    HStack {
                        Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button(allCaptions ? "Name Speaker" : "Confirm Speaker", action: save).keyboardShortcut(.defaultAction)
                            .disabled((allCaptions || target.isEmpty) && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(18).frame(width: 360).onAppear {
                    allCaptions = segment.speaker.map { !controller.isNamedSpeaker($0) && !$0.contains(" + ") } ?? false
                    target = segment.speaker.flatMap { controller.speakerIDs.contains($0) ? $0 : nil } ?? ""
                    name = allCaptions || target.isEmpty ? "" : currentName
                }
            }
    }
    private func save() {
        if allCaptions { controller.nameSpeaker(at: segment.id, name: name) }
        else { controller.correctSpeaker(at: segment.id, speakerID: target.isEmpty ? nil : target, newName: name) }
        editing = false
    }
}
