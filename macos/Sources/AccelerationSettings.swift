import SwiftUI

struct AccelerationSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        picker("Dictation processor", value: model.preferences.value.dictationDevice) { value in model.updatePreferences { $0.dictationDevice = value } }
            .disabled(model.speech.recording || model.busy)
        picker("Transcription processor", value: model.preferences.value.transcriptionDevice) { value in model.updatePreferences { $0.transcriptionDevice = value } }
            .disabled(model.transcription.running)
        Text("Automatic prefers Apple GPU and falls back to CPU if acceleration is unavailable. Installing a recognition model includes both CPU and GPU files. Reading voices and speaker identification use CPU.").font(.caption).foregroundStyle(.secondary)
        #if !arch(arm64)
        Text("Apple GPU acceleration requires an Apple Silicon Mac. This Mac uses CPU recognition.").font(.caption).foregroundStyle(.secondary)
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
