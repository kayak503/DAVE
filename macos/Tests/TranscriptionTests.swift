import Foundation
import AVFoundation

@main struct TranscriptionTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
    @MainActor static func main() async throws {
        let a = TranscriptSegment(start: 0, end: 2, text: "Hello world.", speaker: "Speaker 1")
        let b = TranscriptSegment(start: 3, end: 4.25, text: "Another voice.", speaker: "Speaker 2")
        check(TranscriptDocument.activeID(at: 1, in: [a,b]) == a.id, "Caption lookup")
        check(TranscriptDocument.activeID(at: 2, in: [a,b]) == nil, "No stale caption in silence")
        check(TranscriptDocument.activeID(at: .nan, in: [a,b]) == nil, "Nonfinite lookup")
        check(TranscriptDocument.export([a,b], as: .txt).contains("Speaker 2: Another voice."), "Speaker text export")
        check(TranscriptDocument.export([a,b], as: .srt).contains("00:00:03,000 --> 00:00:04,250"), "SRT timestamps")
        check(TranscriptDocument.export([a], as: .vtt).hasPrefix("WEBVTT\n\n1\n00:00:00.000"), "VTT header/timestamps")
        check(TranscriptDocument.timestamp(3661.125) == "01:01:01,125", "Long timestamps")
        let seamA = TranscriptSegment(start: 26, end: 30, text: "bring three blue notebooks", speaker: nil)
        let seamB = TranscriptSegment(start: 0, end: 5, text: "blue notebooks to the kitchen", speaker: nil)
        let merged = TranscriptDocument.append([seamB], offset: 28, duration: 30, last: false, to: [seamA])
        check(merged.count == 1 && merged[0].text == "bring three blue notebooks to the kitchen", "Partial sentence seam merged without omitted words")
        check(merged[0].start == 26 && merged[0].end == 33, "Absolute overlap timestamps")
        var confirmedSeam = seamA; confirmedSeam.speaker = "Seb"; confirmedSeam.detectedSpeaker = "Speaker 1"; confirmedSeam.speakerEmbedding = [1,0]; confirmedSeam.speakerConfirmed = true
        let duplicateSeam = TranscriptSegment(start: 0, end: 2, text: "blue notebooks", speaker: "Speaker 1", speakerEmbedding: [1,0])
        let deduped = TranscriptDocument.append([duplicateSeam], offset: 28, duration: 30, last: false, to: [confirmedSeam])
        check(deduped == [confirmedSeam], "Embedded confirmed caption survives while duplicate seam is dropped")
        let partialSeam = TranscriptSegment(start: 0, end: 5, text: "blue notebooks to the kitchen", speaker: "Speaker 1", speakerEmbedding: [1,0])
        let trimmed = TranscriptDocument.append([partialSeam], offset: 28, duration: 30, last: false, to: [confirmedSeam])
        check(trimmed.count == 2 && trimmed[0] == confirmedSeam && trimmed[1].text == "to the kitchen" && trimmed[1].speakerEmbedding == nil, "Partial seam keeps confirmed reference and discards misaligned incoming evidence")
        let unmatched = TranscriptDocument.append([TranscriptSegment(start: 0, end: 4, text: "different words", speaker: nil)], offset: 28, duration: 30, last: true, to: [seamA])
        check(unmatched.count == 2, "Uncertain seam preserves words")
        let markup = TranscriptSegment(start: 0, end: 1, text: "A < B & C\r\n-->", speaker: nil)
        check(TranscriptDocument.export([markup], as: .vtt).contains("A &lt; B &amp; C  →"), "Caption markup escaped")
        check(TranscriptDocument.export([markup], as: .txt).contains("A < B & C\r\n-->"), "Plain text remains literal")
        check(!TranscriptDocument.timestamp(Double.greatestFiniteMagnitude).isEmpty, "Timestamp overflow guarded")
        let invalid = TranscriptSegment(start: .nan, end: 3, text: "Bad", speaker: nil)
        check(TranscriptDocument.append([invalid], offset: 0, duration: 30, last: true, to: []).isEmpty, "Invalid timestamps rejected")
        let naming = TranscriptionController(speech: LocalSpeech())
        naming.segments = [a, b, TranscriptSegment(start: 5, end: 6, text: "Hello again.", speaker: "Speaker 1")]
        naming.renameSpeaker("Speaker 1", to: "  John  ")
        check(naming.speakerName("Speaker 1") == "John" && naming.speakerName("Speaker 2") == "Speaker 2", "identity-wide alias without changing other speakers")
        for format in TranscriptFormat.allCases {
            let exported = TranscriptDocument.export(naming.segments, as: format, speakerNames: naming.speakerNames)
            check(exported.contains("John: Hello world.") && exported.contains("John: Hello again.") && exported.contains("Speaker 2: Another voice."), "all formats retain speaker aliases")
        }
        naming.segments.append(TranscriptSegment(start: 7, end: 8, text: "New streamed caption.", speaker: "Speaker 1"))
        check(TranscriptDocument.export(naming.segments, as: .txt, speakerNames: naming.speakerNames).contains("John: New streamed caption."), "future streamed captions share identity")
        naming.renameSpeaker("Speaker 1", to: "Speaker 2")
        naming.renameSpeaker("Speaker 2", to: "Jane")
        check(naming.speakerName("Speaker 1") == "Speaker 2", "display name collisions never merge identities")
        naming.renameSpeaker("Speaker 1", to: " \n ")
        check(naming.speakerName("Speaker 1") == "Speaker 1", "blank restores original label")
        naming.renameSpeaker("Speaker 1", to: "<John>\nSmith")
        check(TranscriptDocument.export([a], as: .vtt, speakerNames: naming.speakerNames).contains("&lt;John&gt; Smith:"), "caption names escape markup and newlines")
        naming.load(URL(fileURLWithPath: "macos/Tests/Fixtures/speech.wav"))
        check(naming.speakerNames.isEmpty, "new file resets aliases")
        naming.shutdown()
        let referenceA = TranscriptSegment(start: 0, end: 1, text: "A", speaker: "A", speakerEmbedding: [1, 0], speakerConfirmed: true)
        let referenceB = TranscriptSegment(start: 1, end: 2, text: "B", speaker: "B", speakerEmbedding: [0, 1], speakerConfirmed: true)
        let borderline = TranscriptSegment(start: 2, end: 3, text: "uncertain", speaker: "B", speakerEmbedding: [0.85, sqrt(1 - 0.85 * 0.85)])
        check(SpeakerLearning.reclassify([referenceA, referenceB, borderline]).last?.speaker == "A", "standard model accepts sufficiently separated example")
        check(SpeakerLearning.reclassify([referenceA, referenceB, borderline], minimumSimilarity: 0.88).last?.speaker == "B", "precision model rejects borderline similarity")
        let corrections = TranscriptionController(speech: LocalSpeech())
        let seb = TranscriptSegment(start: 0, end: 3, text: "Seb introduction", speaker: "Speaker 1", speakerEmbedding: [1, 0])
        let wrongJohn = TranscriptSegment(start: 4, end: 7, text: "John introduction", speaker: "Speaker 1", speakerEmbedding: [0, 1])
        let anotherJohn = TranscriptSegment(start: 8, end: 11, text: "John again", speaker: "Speaker 1", speakerEmbedding: [0.02, 0.99])
        let uncertain = TranscriptSegment(start: 12, end: 15, text: "Uncertain", speaker: "Speaker 1", speakerEmbedding: [0.7, 0.7])
        let short = TranscriptSegment(start: 16, end: 16.4, text: "Yes", speaker: "Speaker 1")
        corrections.segments = [seb, wrongJohn, anotherJohn, uncertain, short]
        corrections.nameSpeaker(at: seb.id, name: "Seb")
        check(corrections.segments.allSatisfy { corrections.speakerName($0.speaker!) == "Seb" }, "First naming applies globally")
        corrections.correctSpeaker(at: wrongJohn.id, speakerID: nil, newName: "John")
        let johnID = corrections.segments[1].speaker!
        check(corrections.speakerName("Speaker 1") == "Seb", "Correction never renames every Seb")
        check(corrections.speakerName(johnID) == "John" && corrections.segments[1].speakerConfirmed == true, "Local correction creates stable identity and locks passage")
        check(corrections.segments[2].speaker == johnID && corrections.segments[2].speakerReclassified == true, "Voice example reclassifies a similar unconfirmed passage")
        check(corrections.segments[0].speaker == "Speaker 1" && corrections.segments[0].speakerConfirmed == true, "Confirmed Seb is protected")
        check(corrections.segments[3].speaker == "Speaker 1" && corrections.segments[4].speaker == "Speaker 1", "Uncertain and missing evidence stay unchanged")
        for format in TranscriptFormat.allCases {
            let exported = TranscriptDocument.export(corrections.segments, as: format, speakerNames: corrections.speakerNames)
            check(exported.contains("Seb: Seb introduction") && exported.contains("John: John introduction") && exported.contains("John: John again"), "Exports retain local and learned identities")
        }
        let future = TranscriptSegment(start: 20, end: 23, text: "New John", speaker: "Speaker 1", speakerEmbedding: [0, 1])
        corrections.segments.append(future); corrections.applySpeakerLearning()
        check(corrections.segments.last?.speaker == johnID, "Confirmed voices classify incoming captions")
        corrections.undoSpeakerEdit()
        check(corrections.segments.count == 6 && corrections.segments.allSatisfy { $0.speaker == "Speaker 1" }, "Undo restores labels while retaining newly streamed captions")
        check(corrections.speakerName("Speaker 1") == "Seb" && !corrections.speakerNames.values.contains("John"), "Undo restores alias map")
        check(SpeakerLearning.cosine([Double.nan], [1]) == nil && SpeakerLearning.cosine([1, 0], [1]) == nil, "Invalid vectors cannot drive reclassification")
        check(SpeakerLabel.name("Speaker 1 + Speaker 2", names: ["Speaker 1": "Seb", "Speaker 2": "John"]) == "Seb + John", "Overlap labels respect aliases")
        corrections.correctSpeaker(at: short.id, speakerID: "Speaker 1")
        check(corrections.segments[4].speakerConfirmed == true, "Short passage can be corrected without inventing voice evidence")
        corrections.load(URL(fileURLWithPath: "macos/Tests/Fixtures/speech.wav"))
        check(!corrections.canUndoSpeakerEdit && corrections.speakerNames.isEmpty, "New file clears correction learning and undo")
        corrections.shutdown()
        if let path = ProcessInfo.processInfo.environment["LOCALVOICE_SPEAKER_EVIDENCE"] {
            let vectors = try JSONDecoder().decode([[Double]].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let learner = TranscriptionController(speech: LocalSpeech())
            let first = TranscriptSegment(start: 0, end: 3, text: "Seb", speaker: "Speaker 1", speakerEmbedding: vectors[0])
            let second = TranscriptSegment(start: 4, end: 7, text: "John", speaker: "Speaker 1", speakerEmbedding: vectors[1])
            let returning = TranscriptSegment(start: 8, end: 11, text: "Seb again", speaker: "Speaker 2", speakerEmbedding: vectors[2])
            learner.segments = [first, second, returning]
            learner.nameSpeaker(at: first.id, name: "Seb")
            learner.correctSpeaker(at: second.id, speakerID: nil, newName: "John")
            check(learner.segments[2].speaker == "Speaker 1", "Actual different passage of same voice reclassifies to confirmed Seb")
            check(learner.segments[0].speaker == "Speaker 1" && learner.speakerName(learner.segments[1].speaker!) == "John", "Actual distinct voices remain separate")
            learner.shutdown(); print("NATIVE_SPEAKER_LEARNING_REAL_OK")
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("native-transcription-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let fixture = URL(fileURLWithPath: "macos/Tests/Fixtures/speech.wav")
        let original = try await TranscriptAudioReader(url: fixture)
        let first = try await original.next()
        check(first != nil && first!.samples.contains { abs($0) > 0.01 }, "Real speech decoded")
        let wav = temp.appendingPathComponent("long.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        var output: AVAudioFile? = try AVAudioFile(forWriting: wav, settings: format.settings)
        let source = first!.samples
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(source.count))!
        buffer.frameLength = AVAudioFrameCount(source.count)
        source.withUnsafeBufferPointer { p in buffer.floatChannelData![0].update(from: p.baseAddress!, count: source.count) }
        let repeats = Int(65 * 16000 / source.count) + 1
        for _ in 0..<repeats { try output!.write(from: buffer) }
        output = nil
        // Closing the output flushes its WAV header before decoding.
        let longURL = temp.appendingPathComponent("long-copy.wav")
        try FileManager.default.copyItem(at: wav, to: longURL)
        let reader = try await TranscriptAudioReader(url: longURL)
        var chunks: [AudioTranscriptChunk] = []
        while let chunk = try await reader.next() { chunks.append(chunk) }
        check(chunks.count >= 3, "Large file decoded incrementally")
        check(chunks.allSatisfy { $0.samples.count <= 480000 }, "Bounded PCM windows")
        check(chunks[0].offset == 0 && chunks[1].offset == 28 && chunks[2].offset == 56, "Chunk offsets")
        check(chunks.last!.last, "Final chunk marked")
        check(Array(chunks[0].samples.suffix(32000)) == Array(chunks[1].samples.prefix(32000)), "Exact overlap samples")
        let cancelled = try await TranscriptAudioReader(url: fixture)
        await cancelled.cancel()
        let afterCancel = try await cancelled.next()
        check(afterCancel == nil, "Cancelled reader releases pending samples")
        let bad = temp.appendingPathComponent("invalid.wav")
        try Data("not audio".utf8).write(to: bad)
        do { _ = try await TranscriptAudioReader(url: bad); fatalError("Malformed audio accepted") } catch {}
        if ProcessInfo.processInfo.environment["LOCALVOICE_TRANSCRIPTION_REAL"] == "1" {
            let device = ProcessInfo.processInfo.environment["LOCALVOICE_TRANSCRIPTION_DEVICE"] ?? "cpu"
            let controller = TranscriptionController(speech: LocalSpeech())
            controller.load(fixture); check(!controller.hasPlaybackSession, "Import does not initialize audio playback"); controller.start(modelID: "whisper-tiny", device: device)
            let deadline = Date().addingTimeInterval(120)
            while controller.running && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            check(!controller.running && controller.progress == 1, "Real controller finishes: \(controller.status)")
            let text = TranscriptDocument.export(controller.segments, as: .txt).lowercased()
            check(text.contains("garden") && text.contains("notebooks") && text.contains("kitchen"), "Actual Whisper captions contain fixture words: \(text)")
            check(controller.segments.allSatisfy { $0.start >= 0 && $0.end > $0.start && $0.end <= controller.duration + 0.1 }, "Real caption bounds")
            controller.start(modelID: "whisper-tiny", device: device)
            try await Task.sleep(nanoseconds: 150_000_000)
            controller.cancel(); controller.start(modelID: "whisper-tiny", device: device)
            let restartDeadline = Date().addingTimeInterval(120)
            while controller.running && Date() < restartDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
            check(!controller.running && controller.progress == 1 && !controller.segments.isEmpty, "Immediate cancel/restart preserves new real inference: \(controller.status)")
            controller.load(longURL); controller.start(modelID: "whisper-tiny", device: device)
            let longDeadline = Date().addingTimeInterval(180)
            var observedPartial = false
            while controller.running && Date() < longDeadline {
                if !controller.segments.isEmpty && controller.progress > 0 && controller.progress < 1 { observedPartial = true }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            check(!controller.running && controller.progress == 1, "Large real recording finishes: \(controller.status)")
            check(observedPartial, "Captions appear incrementally before large file completes")
            check(controller.segments.contains { $0.end > 56 }, "Actual captions extend beyond the third chunk boundary")
            if device == "metal" { check(controller.accelerationStatus.contains("Apple Metal"), "Actual GPU status reaches native controller"); print("NATIVE_TRANSCRIPTION_METAL_OK") }
            controller.shutdown()
            print("NATIVE_TRANSCRIPTION_REAL_OK")
        }
        if ProcessInfo.processInfo.environment["LOCALVOICE_TRANSCRIPTION_PLAYBACK"] == "1" {
            let controller = TranscriptionController(speech: LocalSpeech())
            controller.load(fixture)
            check(!controller.hasPlaybackSession, "Import does not touch playback hardware")
            let metadataDeadline = Date().addingTimeInterval(5)
            while controller.duration == 0 && Date() < metadataDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
            check(controller.duration > 0 && !controller.hasPlaybackSession, "Audio metadata loads without playback")
            controller.togglePlayback()
            let playbackDeadline = Date().addingTimeInterval(10)
            while controller.playbackTime < 0.3 && controller.playing && Date() < playbackDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
            check(controller.playbackTime >= 0.3, "Real recording playback advances: \(controller.status)")
            controller.togglePlayback(); let paused = controller.playbackTime
            try await Task.sleep(nanoseconds: 300_000_000)
            check(!controller.playing && abs(controller.playbackTime - paused) < 0.1, "Pause keeps position")
            controller.seek(1); controller.rate = 1.5; controller.togglePlayback()
            try await Task.sleep(nanoseconds: 500_000_000)
            check(controller.playbackTime > 1.3, "Seek and changed playback rate advance")
            controller.load(longURL); check(!controller.hasPlaybackSession && !controller.playing && controller.playbackTime == 0, "New import stops old player without initializing another")
            try await Task.sleep(nanoseconds: 200_000_000)
            check(controller.playbackTime == 0, "Stale player callbacks cannot change new recording")
            controller.shutdown(); print("NATIVE_TRANSCRIPTION_PLAYBACK_OK")
        }
        print("NATIVE_TRANSCRIPTION_OK")
    }
}
