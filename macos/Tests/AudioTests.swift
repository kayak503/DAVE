import Foundation
import AppKit

@main struct AudioTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let speech = LocalSpeech()
            do {
                let longText = "The garden is quiet today. We are testing native audio playback, pausing during preparation, and changing speed while the same audio is playing. This recording stays on the computer."
                var finished = false
                let reading = Task { @MainActor in try await speech.speak(longText, model: "system", voice: "", rate: 1); finished = true }
                try await Task.sleep(for: .milliseconds(150))
                speech.pause()
                try await Task.sleep(for: .milliseconds(500))
                guard !finished, speech.status == "Paused" else { throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Paused playback unexpectedly completed or lost paused state"]) }
                speech.setRate(2)
                speech.resume()
                try await reading.value
                guard let measured = speech.timing, measured.preparation > 0, measured.audioDuration > 0, !speech.preparing else {
                    throw NSError(domain: "Test", code: 3, userInfo: [NSLocalizedDescriptionKey: "Actual audio generation timing missing or preparation never ended"])
                }
                let old = Task { @MainActor in try await speech.speak(longText, model: "system", voice: "", rate: 1) }
                try await Task.sleep(for: .milliseconds(80))
                old.cancel(); speech.stopSpeaking()
                let replacement = Task { @MainActor in try await speech.speak("The new sentence plays after seeking.", model: "system", voice: "", rate: 2) }
                do { try await old.value; throw NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cancelled speech unexpectedly succeeded"]) } catch is CancellationError { }
                try await replacement.value
                try await speech.speak("The local model also plays natively.", model: "kokoro-q8", voice: "af_heart", rate: 1.5)
                let models = try await speech.models()
                guard let voices = models.first(where: { $0.id == "kokoro-q8" })?.voices,
                      Set(voices.map(\.id)) == Set(["af_heart", "am_michael", "bf_emma", "bm_george"]) else { fatalError("Voice catalog missing") }
                for voice in voices {
                    try await speech.speak("Hello, this is my voice.", model: "kokoro-q8", voice: voice.id, rate: 1)
                }
                let generator = LocalSpeech()
                let buffer = ReadingBuffer<LocalSpeech.PreparedSpeech>(prepare: { i in
                    try await generator.prepareSpeech("Sentence number \(i + 1) is prepared ahead of playback.", model: "kokoro-q8", voice: "af_heart")
                }, dispose: { $0.dispose() })
                buffer.fill(from: 0, count: 4, ahead: 3)
                let prepared = try await buffer.value(at: 0)
                let playback = Task { try await speech.playPrepared(prepared, rate: 1, paused: true) }
                let upcoming = try await buffer.value(at: 3)
                guard buffer.readyCount == 4, speech.status == "Paused",
                      FileManager.default.fileExists(atPath: upcoming.url.path) else { fatalError("Lookahead did not run while playback was paused") }
                speech.setRate(2); speech.resume(); try await playback.value
                buffer.fill(from: 3, count: 4, ahead: 3)
                let reused = try await buffer.value(at: 3)
                guard reused.url == upcoming.url else { fatalError("Seek regenerated cached audio") }
                try await speech.playPrepared(reused, rate: 2)
                buffer.cancel(); generator.shutdown()
                speech.shutdown()
                print("NATIVE_AUDIO_OK")
                exit(0)
            } catch { speech.shutdown(); fputs("Native audio failure: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
}
