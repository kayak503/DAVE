import SwiftUI

struct AccelerationSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        picker("Dictation processor", value: model.preferences.value.dictationDevice) { value in model.updatePreferences { $0.dictationDevice = value } }
            .disabled(model.speech.recording || model.busy)
        picker("Transcription processor", value: model.preferences.value.transcriptionDevice) { value in model.updatePreferences { $0.transcriptionDevice = value } }
            .disabled(model.transcription.running)
        Text("Automatic uses Apple GPU when the model’s GPU files are installed; otherwise it uses CPU. Apple GPU requires Metal and never silently switches to CPU. Reading and speaker labeling currently use CPU.").font(.caption).foregroundStyle(.secondary)
        #if arch(arm64)
        ForEach(model.models.filter { $0.variantOf != nil && ($0.variantOf == model.preferences.value.sttModel || $0.variantOf == model.preferences.value.transcriptionModel) }) { item in
            HStack {
                VStack(alignment: .leading) {
                    Text(item.name)
                    Text("\(Int(item.sizeMB)) MB · \(item.installed ? "GPU files ready" : "separate download for Metal")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if item.installed {
                    Button("Remove GPU Files") { model.removeModel(item.id) }
                        .disabled(model.busy || model.transcription.running || model.speech.recording)
                } else {
                    Button(model.busy ? "Downloading…" : "Download GPU Files") { model.installModel(item.id) }
                        .disabled(model.busy || model.transcription.running || model.speech.recording)
                }
            }
        }
        #else
        Text("Apple GPU acceleration currently requires an Apple Silicon Mac. This Mac uses CPU recognition.").font(.caption).foregroundStyle(.secondary)
        #endif
        if !model.speech.accelerationStatus.isEmpty { Text("Last dictation: \(model.speech.accelerationStatus)").font(.caption).foregroundStyle(.secondary) }
        if !model.transcription.accelerationStatus.isEmpty { Text("Last transcription: \(model.transcription.accelerationStatus)").font(.caption).foregroundStyle(.secondary) }
    }
    private func picker(_ title: String, value: String, change: @escaping (String) -> Void) -> some View {
        Picker(title, selection: Binding(get: { value }, set: change)) {
            Text("Automatic").tag("auto")
            Text("CPU").tag("cpu")
            #if arch(arm64)
            Text("Apple GPU (Metal)").tag("metal")
            #endif
        }
    }
}
