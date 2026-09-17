import AppKit
import AVFoundation
import Combine

struct TranscriptSegment: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var speaker: String?
    var speakerEmbedding: [Double]? = nil
    var speakerConfirmed: Bool? = nil
    var detectedSpeaker: String? = nil
    var speakerReclassified: Bool? = nil
}

enum SpeakerLabel {
    static func name(_ id: String, names: [String: String]) -> String {
        names[id] ?? id.components(separatedBy: " + ").map { names[$0] ?? $0 }.joined(separator: " + ")
    }
}
enum TranscriptFormat: String, CaseIterable { case txt, srt, vtt }
enum TranscriptDocument {
    static func timestamp(_ seconds: Double, separator: String = ",") -> String {
        let ms = Int((min(359_999_999, max(0, seconds.isFinite ? seconds : 0)) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, separator, ms % 1000)
    }
    static func activeID(at time: Double, in segments: [TranscriptSegment]) -> UUID? {
        guard time.isFinite else { return nil }
        return segments.first { $0.start <= time && time < $0.end }?.id
    }
    static func export(_ segments: [TranscriptSegment], as format: TranscriptFormat, speakerNames: [String: String] = [:]) -> String {
        let rows = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func line(_ s: TranscriptSegment) -> String {
            let value = (s.speaker.map { "\(SpeakerLabel.name($0, names: speakerNames)): " } ?? "") + s.text
            if format == .txt { return value }
            let plain = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "-->", with: "→")
            return plain.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        switch format {
        case .txt: return rows.map(line).joined(separator: "\n\n") + "\n"
        case .srt, .vtt:
            let separator = format == .vtt ? "." : ","
            let body = rows.enumerated().map { index, s in
                "\(index + 1)\n\(timestamp(s.start, separator: separator)) --> \(timestamp(max(s.start + 0.01, s.end), separator: separator))\n\(line(s))\n"
            }.joined(separator: "\n")
            return (format == .vtt ? "WEBVTT\n\n" : "") + body
        }
    }
    /// Keep coarse model captions at seams; remove only matching suffix/prefix words in overlapping time ranges.
    static func append(_ incoming: [TranscriptSegment], offset: Double, duration: Double, last: Bool, to existing: [TranscriptSegment]) -> [TranscriptSegment] {
        var result = existing
        func normalized(_ word: Substring) -> String { String(word).lowercased().trimmingCharacters(in: .punctuationCharacters) }
        for var segment in incoming.sorted(by: { $0.start < $1.start }) {
            guard segment.start.isFinite, segment.end.isFinite, segment.end > segment.start,
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            segment.start = max(0, segment.start) + offset
            segment.end = min(duration, segment.end) + offset
            guard segment.end > segment.start else { continue }
            segment.text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if var previous = result.last, previous.end > segment.start, (previous.detectedSpeaker ?? previous.speaker) == segment.speaker {
                let protectedEvidence = previous.speakerEmbedding != nil || segment.speakerEmbedding != nil || previous.speakerConfirmed == true
                let left = previous.text.split(whereSeparator: { $0.isWhitespace })
                let right = segment.text.split(whereSeparator: { $0.isWhitespace })
                var matched = 0
                for count in (1...max(1, min(left.count, right.count))).reversed() {
                    if count <= left.count, count <= right.count,
                       left.suffix(count).map(normalized) == right.prefix(count).map(normalized) { matched = count; break }
                }
                if matched > 0 {
                    if matched == right.count {
                        if !protectedEvidence { previous.end = max(previous.end, segment.end); result[result.count - 1] = previous }
                        continue
                    }
                    segment.text = right.dropFirst(matched).joined(separator: " ")
                    // Trimming text breaks its correspondence to the original voice sample.
                    segment.speakerEmbedding = nil
                    if !protectedEvidence && segment.end - previous.start <= 40 {
                        previous.text += " " + segment.text; previous.end = max(previous.end, segment.end)
                        result[result.count - 1] = previous; continue
                    }
                }
            }
            result.append(segment)
        }
        return result
    }

}

struct AudioTranscriptChunk { let samples: [Float]; let offset: Double; let last: Bool }
/// Decoder retains only a 30-second window and two seconds of overlap, regardless of file size.
actor TranscriptAudioReader {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let inputBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private var pending: [Float] = []
    private var offset = 0
    private var ended = false
    private let window = 480_000
    private let stride = 448_000
    let duration: Double
    init(url: URL) async throws {
        file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard inputFormat.sampleRate > 0,
              let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let conversion = AVAudioConverter(from: inputFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 8192),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else {
            throw NSError(domain: "Transcribe", code: 1, userInfo: [NSLocalizedDescriptionKey: "This audio format cannot be decoded."])
        }
        converter = conversion; inputBuffer = input; outputBuffer = output
        duration = Double(file.length) / inputFormat.sampleRate
    }
    func cancel() { converter.reset(); pending.removeAll(); ended = true }

    func next() throws -> AudioTranscriptChunk? {
        try Task.checkCancellation()
        while pending.count < window && !ended {
            var conversionError: NSError?
            var readError: Error?
            let state = converter.convert(to: outputBuffer, error: &conversionError) { [file, inputBuffer] requested, flag in
                do {
                    let remaining = file.length - file.framePosition
                    guard remaining > 0 else { flag.pointee = .endOfStream; return nil }
                    try file.read(into: inputBuffer, frameCount: min(requested, inputBuffer.frameCapacity, AVAudioFrameCount(min(Int64(UInt32.max), remaining))))
                    if inputBuffer.frameLength == 0 { flag.pointee = .endOfStream; return nil }
                    flag.pointee = .haveData; return inputBuffer
                } catch { readError = error; flag.pointee = .endOfStream; return nil }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if state == .error { throw NSError(domain: "Transcribe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Audio decoding failed."]) }
            if let values = outputBuffer.floatChannelData?[0], outputBuffer.frameLength > 0 {
                pending.append(contentsOf: UnsafeBufferPointer(start: values, count: Int(outputBuffer.frameLength)).map { $0.isFinite ? max(-1, min(1, $0)) : 0 })
            }
            if state == .endOfStream || (state == .inputRanDry && outputBuffer.frameLength == 0) { ended = true }
            try Task.checkCancellation()
        }
        guard !pending.isEmpty else { return nil }
        let count = min(window, pending.count)
        let last = ended && pending.count <= window
        let result = AudioTranscriptChunk(samples: Array(pending.prefix(count)), offset: Double(offset) / 16000, last: last)
        if last { pending.removeAll() } else { pending.removeFirst(stride); offset += stride }
        return result
    }
}

/// All AVAudioPlayer interaction is isolated from the UI, including construction and time reads.
private final class TranscriptPlayback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "localvoice.transcript-playback")
    private let lock = NSLock()
    private var valid = true
    private var player: AVAudioPlayer?
    private var timer: DispatchSourceTimer?
    private let url: URL
    private var report: (@Sendable (Double, Bool, String?) -> Void)?
    init(url: URL) { self.url = url }
    private var active: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func play(at time: Double, rate: Float, report: @escaping @Sendable (Double, Bool, String?) -> Void) {
        queue.async { [self] in
            guard active else { return }
            self.report = report
            do {
                if player == nil { player = try AVAudioPlayer(contentsOf: url); player?.enableRate = true }
                guard active, let player else { return }
                player.currentTime = time; player.rate = rate
                guard active else { return }
                let started = player.play()
                guard active else { player.stop(); return }
                guard started else { report(time, false, "This recording could not be played."); return }
                timer?.cancel()
                let timer = DispatchSource.makeTimerSource(queue: queue); self.timer = timer
                timer.schedule(deadline: .now(), repeating: .milliseconds(100))
                timer.setEventHandler { [weak self] in
                    guard let self, self.active, let player = self.player else { return }
                    let position = player.currentTime, isPlaying = player.isPlaying
                    self.report?(position, isPlaying, nil)
                    if !isPlaying { self.timer?.cancel(); self.timer = nil }
                }
                timer.resume()
            } catch { if active { report(time, false, error.localizedDescription) } }
        }
    }
    func pause() { queue.async { [self] in guard active else { return }; timer?.cancel(); timer = nil; player?.pause() } }
    func seek(_ time: Double) { queue.async { [self] in guard active else { return }; player?.currentTime = time } }
    func setRate(_ rate: Float) { queue.async { [self] in guard active else { return }; player?.rate = rate } }
    func stop() {
        lock.lock(); valid = false; lock.unlock()
        queue.async { [self] in timer?.cancel(); timer = nil; player?.stop(); player = nil; report = nil }
    }
}

enum SpeakerLearning {
    static func cosine(_ a: [Double], _ b: [Double]) -> Double? {
        guard !a.isEmpty, a.count == b.count, a.count <= 4096, a.allSatisfy({ $0.isFinite }), b.allSatisfy({ $0.isFinite }) else { return nil }
        let aa = a.reduce(0) { $0 + $1 * $1 }, bb = b.reduce(0) { $0 + $1 * $1 }
        guard aa > 0.000001, bb > 0.000001 else { return nil }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } / sqrt(aa * bb)
    }
    static func reclassify(_ input: [TranscriptSegment], minimumSimilarity: Double = 0.82) -> [TranscriptSegment] {
        let references = input.filter { $0.speakerConfirmed == true && $0.speaker != nil && $0.speakerEmbedding != nil }
        // A single example cannot distinguish one person's voice from all the others.
        let identities = Set(references.compactMap(\.speaker))
        return input.map { original in
            guard original.speakerConfirmed != true else { return original }
            var row = original
            if row.speakerReclassified == true { row.speaker = row.detectedSpeaker; row.speakerReclassified = false }
            guard identities.count >= 2, let vector = row.speakerEmbedding else { return row }
            var scores: [String: Double] = [:]
            for reference in references {
                if let id = reference.speaker, let other = reference.speakerEmbedding, let score = cosine(vector, other) { scores[id] = max(scores[id] ?? -1, score) }
            }
            let ranked = scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            guard ranked.count >= 2, ranked[0].value >= minimumSimilarity, ranked[0].value - ranked[1].value >= 0.12, ranked[0].key != row.speaker else { return row }
            row.detectedSpeaker = row.speaker; row.speaker = ranked[0].key; row.speakerReclassified = true
            return row
        }
    }
}

@MainActor final class TranscriptionController: ObservableObject {
    @Published var fileURL: URL?
    @Published var segments: [TranscriptSegment] = []
    @Published private(set) var speakerNames: [String: String] = [:]
    func speakerName(_ id: String) -> String { SpeakerLabel.name(id, names: speakerNames) }
    func renameSpeaker(_ id: String, to name: String) {
        let cleaned = name.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        if cleaned.isEmpty { speakerNames.removeValue(forKey: id) }
        else { speakerNames[id] = String(cleaned.prefix(80)) }
    }
    private struct SpeakerEditSnapshot { var segments: [TranscriptSegment]; var names: [String: String] }
    private var speakerUndo: [SpeakerEditSnapshot] = []
    @Published private(set) var canUndoSpeakerEdit = false
    var speakerIDs: [String] { Array(Set(segments.compactMap(\.speaker).filter { !$0.contains(" + ") }).union(speakerNames.keys)).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    func isNamedSpeaker(_ id: String) -> Bool { speakerNames[id] != nil }
    private func rememberSpeakerEdit() {
        speakerUndo.append(SpeakerEditSnapshot(segments: segments, names: speakerNames))
        if speakerUndo.count > 20 { speakerUndo.removeFirst() }
        canUndoSpeakerEdit = true
    }
    func nameSpeaker(at captionID: UUID, name: String) {
        guard let index = segments.firstIndex(where: { $0.id == captionID }), let id = segments[index].speaker, !id.contains(" + "), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        rememberSpeakerEdit(); renameSpeaker(id, to: name)
        segments[index].speakerConfirmed = true
        applySpeakerLearning()
    }
    func correctSpeaker(at captionID: UUID, speakerID: String?, newName: String = "") {
        guard let index = segments.firstIndex(where: { $0.id == captionID }) else { return }
        let cleaned = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard speakerID.map({ speakerIDs.contains($0) }) == true || !cleaned.isEmpty else { return }
        rememberSpeakerEdit()
        let target = speakerID ?? "Person-\(UUID().uuidString)"
        if speakerID == nil { renameSpeaker(target, to: cleaned) }
        if segments[index].speakerReclassified != true { segments[index].detectedSpeaker = segments[index].speaker }
        segments[index].speaker = target; segments[index].speakerConfirmed = true; segments[index].speakerReclassified = false
        applySpeakerLearning()
    }
    func applySpeakerLearning() {
        let before = segments
        segments = SpeakerLearning.reclassify(segments, minimumSimilarity: transcriptSpeakerModelID == "precision" ? 0.88 : 0.82)
        let count = zip(before, segments).filter { $0.speaker != $1.speaker }.count
        let references = Set(segments.filter { $0.speakerConfirmed == true && $0.speakerEmbedding != nil }.compactMap(\.speaker)).count
        status = count > 0 ? "Passage confirmed. Updated \(count) other speaker assignments using your voice examples. Undo is available." : references < 2 ? "Passage confirmed. Confirm clear passages from two different people to help distinguish their voices." : "Passage confirmed. Other uncertain assignments were left unchanged."
    }
    func undoSpeakerEdit() {
        guard let snapshot = speakerUndo.popLast() else { return }
        let saved = Dictionary(uniqueKeysWithValues: snapshot.segments.map { ($0.id, $0) })
        segments = segments.map { saved[$0.id] ?? $0 }; speakerNames = snapshot.names
        segments = SpeakerLearning.reclassify(segments, minimumSimilarity: transcriptSpeakerModelID == "precision" ? 0.88 : 0.82)
        canUndoSpeakerEdit = !speakerUndo.isEmpty; status = "Speaker edit undone."
    }
    private func resetSpeakerEdits() { speakerUndo = []; canUndoSpeakerEdit = false }
    @Published var duration: Double = 0
    @Published var progress: Double = 0
    @Published var running = false
    @Published var status = ""
    @Published var accelerationStatus = ""
    @Published var separateSpeakers = false
    @Published var expectedSpeakers = 0
    private var transcriptSpeakerModelID = "compact"
    @Published var speakerModelID = "compact"
    @Published var speakerModels: [SpeakerModelOption] = []
    var selectedSpeakerModel: SpeakerModelOption? { speakerModels.first { $0.id == speakerModelID } }
    func selectSpeakerModel(_ id: String) {
        guard !running, !installingSpeakers, speakerModels.contains(where: { $0.id == id }) else { return }
        speakerModelID = id; onSpeakerModelChange?(id); speakerModelInstalled = selectedSpeakerModel?.installed ?? false
    }
    @Published var speakerModelInstalled = false
    @Published var installingSpeakers = false
    @Published var playbackTime: Double = 0
    @Published var playing = false
    @Published var rate: Float = 1 { didSet { playbackWorker?.setRate(rate) } }
    private let speech: LocalSpeech
    private var task: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var playbackTimeout: Task<Void, Never>?
    private var playbackWorker: TranscriptPlayback?
    private var playbackGeneration = UUID()
    private var fileGeneration = UUID()
    var hasPlaybackSession: Bool { playbackWorker != nil }
    private var generation = UUID()
    private let onSpeakerModelChange: ((String) -> Void)?
    init(speech: LocalSpeech, speakerModelID: String = "compact", onSpeakerModelChange: ((String) -> Void)? = nil) {
        self.speech = speech; self.speakerModelID = speakerModelID; self.onSpeakerModelChange = onSpeakerModelChange
    }
    var activeCaption: UUID? { TranscriptDocument.activeID(at: playbackTime, in: segments) }
    func refreshSpeakerModel() {
        guard !installingSpeakers && !running else { return }
        let previous = modelTask
        modelTask = Task { await previous?.value; guard !Task.isCancelled else { return }; speakerModels = (try? await speech.speakerModels()) ?? []; speakerModelInstalled = selectedSpeakerModel?.installed ?? false }
    }
    func installSpeakerModel() {
        guard !installingSpeakers && !running else { return }; installingSpeakers = true; status = "Downloading the local speaker model…"
        let previous = modelTask
        modelTask = Task { await previous?.value; defer { installingSpeakers = false }; do { try Task.checkCancellation(); try await speech.installDiarization(model: speakerModelID); speakerModels = try await speech.speakerModels(); speakerModelInstalled = selectedSpeakerModel?.installed ?? false; status = "Speaker model ready. Audio stays on this Mac." } catch { status = error.localizedDescription } }
    }
    func chooseFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in guard response == .OK, let url = panel.url else { return }; Task { @MainActor in self?.load(url) } }
    }
    func load(_ url: URL) {
        cancel(); stopPlayback(); fileURL = url; segments = []; speakerNames = [:]; resetSpeakerEdits(); progress = 0; duration = 0; playbackTime = 0; status = "Ready to transcribe locally."
        let token = UUID(); fileGeneration = token
        Task {
            let value = await Task.detached { () -> Double? in
                guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
                return Double(file.length) / file.processingFormat.sampleRate
            }.value
            if let value, token == fileGeneration { duration = value.isFinite ? value : 0 }
        }
    }
    func start(modelID: String, device: String = "cpu") {
        guard let url = fileURL, !running, !installingSpeakers else { return }
        guard !separateSpeakers || speakerModelInstalled else { status = "Download the speaker model to distinguish voices locally."; return }
        segments = []; speakerNames = [:]; resetSpeakerEdits(); progress = 0; running = true; accelerationStatus = "Checking recognition device…"; status = "Opening audio…"
        transcriptSpeakerModelID = speakerModelID
        let token = UUID(); generation = token
        let jobID = UUID().uuidString, separate = separateSpeakers, speakers = expectedSpeakers, speakerModel = speakerModelID
        let previous = task, modelSetup = modelTask
        task = Task {
            await previous?.value
            await modelSetup?.value
            var decoder: TranscriptAudioReader?
            do {
                try Task.checkCancellation()
                let models = try await speech.models()
                guard recognitionReady(models, id: modelID, device: device) else {
                    throw NSError(domain: "Transcribe", code: 10, userInfo: [NSLocalizedDescriptionKey: device == "metal" ? "Download GPU files for this model in Settings → Acceleration." : "Download the selected model in Models, or its GPU files in Settings → Acceleration, then try again."])
                }
                let stream = try await TranscriptAudioReader(url: url); decoder = stream
                let total = stream.duration
                guard token == generation else { await stream.cancel(); return }
                duration = total.isFinite ? total : 0
                while let chunk = try await stream.next() {
                    try Task.checkCancellation(); guard token == generation else { throw CancellationError() }
                    status = "Transcribing \(TranscriptDocument.timestamp(chunk.offset, separator: ".")) of \(TranscriptDocument.timestamp(duration, separator: "."))…"
                    let captions = try await speech.transcribeChunk(samples: chunk.samples, model: modelID, jobID: jobID, separateSpeakers: separate, expectedSpeakers: speakers, device: device, speakerModel: speakerModel)
                    accelerationStatus = speech.accelerationStatus
                    try Task.checkCancellation(); guard token == generation else { throw CancellationError() }
                    segments = TranscriptDocument.append(captions, offset: chunk.offset, duration: Double(chunk.samples.count) / 16000, last: chunk.last, to: segments)
                    segments = SpeakerLearning.reclassify(segments, minimumSimilarity: transcriptSpeakerModelID == "precision" ? 0.88 : 0.82)
                    progress = duration > 0 ? min(1, (chunk.offset + Double(chunk.samples.count) / 16000) / duration) : 0
                }
                if token == generation { progress = 1; status = segments.isEmpty ? "Finished. No speech was detected." : "Transcript ready. Click a caption to listen." }
            } catch is CancellationError { if token == generation { status = "Stopped. Completed captions are available to copy or export." } }
            catch { if token == generation { status = "\(error.localizedDescription) Completed captions are preserved." } }
            if let decoder { await decoder.cancel() }
            try? await speech.resetTranscription(jobID: jobID)
            if token == generation { running = false; task = nil }
        }
    }
    func cancel() { let wasRunning = running; task?.cancel(); if wasRunning { speech.cancelPendingOperations() }; generation = UUID(); running = false; status = "Stopped. Completed captions are available to copy or export." }
    func togglePlayback() {
        guard let url = fileURL else { return }
        playbackTimeout?.cancel(); playbackGeneration = UUID()
        if playing { playbackWorker?.pause(); playing = false; return }
        if duration > 0 && playbackTime >= duration - 0.1 { playbackTime = 0 }
        let worker = playbackWorker ?? TranscriptPlayback(url: url); playbackWorker = worker
        let token = playbackGeneration, initialTime = playbackTime
        playing = true
        worker.play(at: playbackTime, rate: rate) { [weak self] time, active, error in
            Task { @MainActor in
                guard let self, self.playbackGeneration == token else { return }
                if let error { self.playing = false; self.status = error; return }
                self.playbackTime = time.isFinite ? time : 0
                if !active { self.playing = false }
            }
        }
        playbackTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            guard let self, playbackGeneration == token, playing else { return }
            if abs(playbackTime - initialTime) < 0.05 {
                stopPlayback(); status = "Playback did not start. Check your Mac’s sound output, then try again."
            }
        }
    }
    func seek(_ time: Double) {
        guard time.isFinite else { return }
        playbackTime = max(0, min(duration, time)); playbackWorker?.seek(playbackTime)
    }
    func playCaption(_ segment: TranscriptSegment) { seek(segment.start); if !playing { togglePlayback() } }
    private func stopPlayback() {
        playbackGeneration = UUID(); playbackTimeout?.cancel(); playbackTimeout = nil
        playbackWorker?.stop(); playbackWorker = nil; playing = false
    }
    func copy() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(TranscriptDocument.export(segments, as: .txt, speakerNames: speakerNames), forType: .string); status = "Transcript copied." }
    func export(_ format: TranscriptFormat) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "Transcript") + "." + format.rawValue
        let text = TranscriptDocument.export(segments, as: format, speakerNames: speakerNames)
        panel.begin { [weak self] response in guard response == .OK, let url = panel.url else { return }; Task { @MainActor in do { try text.write(to: url, atomically: true, encoding: .utf8); self?.status = "Transcript saved." } catch { self?.status = error.localizedDescription } } }
    }
    func shutdown() { cancel(); modelTask?.cancel(); modelTask = nil; stopPlayback(); speech.shutdown() }
}
