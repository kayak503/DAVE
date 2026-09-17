import Foundation
import AVFoundation
import Combine
import Darwin

struct SpeakerModelOption: Decodable, Identifiable { var id: String; var name: String; var sizeMB: Double; var description: String; var installed: Bool }

struct ReadingVoice: Identifiable, Decodable, Equatable { var id: String; var name: String }

struct LocalModel: Identifiable, Decodable {
    var id: String; var name: String; var task: String; var tier: String; var installed: Bool; var sizeMB: Double; var voices: [ReadingVoice]?; var description: String?; var memoryGB: Double?; var variantOf: String? = nil
}
func recognitionReady(_ models: [LocalModel], id: String, device: String) -> Bool {
    let cpu = models.contains { $0.id == id && $0.installed }
    let gpu = models.contains { $0.variantOf == id && $0.installed }
    return device == "metal" ? gpu : cpu || gpu
}

struct AccelerationResult: Decodable { var requested: String; var provider: String; var detail: String }
private func speechError(_ message: String) -> NSError { NSError(domain: "LocalSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

private final class PlaybackPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    var active: Bool { lock.lock(); defer { lock.unlock() }; return allowed }
    func cancel() { lock.lock(); allowed = false; lock.unlock() }
}

@MainActor final class LocalSpeech: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var recording = false
    @Published var level: Double = 0
    @Published var history = LevelHistory()
    @Published var preparing = false
    @Published var preparationStarted: Date?
    @Published var timing: SpeechTiming?
    @Published var timingModel = ""
    @Published var status = "Ready"
    @Published var accelerationStatus = ""
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var receiveBuffer = Data()
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var session: URL?
    private var player: AVAudioPlayer?
    private let audioQueue = DispatchQueue(label: "localvoice.playback")
    private var playbackPermit: PlaybackPermit?
    private var playbackStartTimeout: Task<Void, Never>?
    private var playback: CheckedContinuation<Void, Error>?
    private var synthesizer: AVSpeechSynthesizer?
    private var generation = UUID()
    private var preparingServiceSpeech = false
    private var rate: Float = 1
    private var wantsPause = false
    private var recorder: AVAudioRecorder?
    private var meter: Timer?
    private var recordingURL: URL?
    private var recordingStarted: Date?
    private var recordingGeneration = UUID()
    override init() { super.init() }
    private func folder() throws -> URL {
        if let session { return session }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("localvoice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); session = url; return url
    }
    private func launch() throws {
        if process?.isRunning == true { return }
        let env = ProcessInfo.processInfo.environment
        let resources = Bundle.main.resourceURL!
        let node = env["LOCALVOICE_NODE"] ?? resources.appendingPathComponent("runtime/node").path
        let backend = env["LOCALVOICE_BACKEND"] ?? resources.appendingPathComponent("backend/service.mjs").path
        guard FileManager.default.isExecutableFile(atPath: node) else { throw speechError("The bundled speech runtime is missing. Rebuild or reinstall Local Voice.") }
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        p.executableURL = URL(fileURLWithPath: node); p.arguments = [backend]
        var environment = env; environment["LOCALVOICE_SESSION"] = try folder().path
        environment["LOCALVOICE_WHISPER_BIN"] = env["LOCALVOICE_WHISPER_BIN"] ?? resources.appendingPathComponent("runtime/whisper-cli").path
        p.environment = environment; p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard let self, self.process === p else { return }; self.receive(data)
            }
        }
        p.terminationHandler = { [weak self] _ in Task { @MainActor [weak self] in
            guard let self, self.process === p else { return }
            self.failService("The local speech service stopped. Try the operation again.")
        } }
        process = p
        do { try p.run() } catch { failService(error.localizedDescription); throw error }
    }
    private func failService(_ message: String) {
        output?.readabilityHandler = nil; try? output?.close(); try? input?.close(); output = nil; input = nil
        process?.terminationHandler = nil
        if let running = process, running.isRunning {
            running.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if running.isRunning { kill(running.processIdentifier, SIGKILL) }
            }
        }
        process = nil; receiveBuffer.removeAll()
        let waits = pending; pending.removeAll(); for c in waits.values { c.resume(throwing: speechError(message)) }
    }
    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        receiveBuffer.append(data)
        guard receiveBuffer.count < 2_000_000 else { failService("The speech service returned an oversized response."); return }
        while let index = receiveBuffer.firstIndex(of: 10) {
            let line = receiveBuffer[..<index]; receiveBuffer.removeSubrange(...index)
            guard let value = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let id = value["id"] as? String, let continuation = pending.removeValue(forKey: id) else { continue }
            if let error = value["error"] as? String { continuation.resume(throwing: speechError(error)) }
            else { do { continuation.resume(returning: try JSONSerialization.data(withJSONObject: value["result"] ?? [:])) } catch { continuation.resume(throwing: error) } }
        }
    }
    private func request(_ command: String, _ values: [String: Any] = [:]) async throws -> Data {
        try Task.checkCancellation(); try launch()
        let id = UUID().uuidString; var body = values; body["id"] = id; body["command"] = command
        var bytes = try JSONSerialization.data(withJSONObject: body); bytes.append(10)
        guard bytes.count <= 65536 else { throw speechError("This request is too long.") }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do { try input?.write(contentsOf: bytes) } catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            }
        }, onCancel: { Task { @MainActor [weak self] in
            guard let self, self.pending[id] != nil else { return }
            self.failService("Speech operation cancelled.")
        } })
    }
    func transcribeChunk(samples: [Float], model: String, jobID: String, separateSpeakers: Bool, expectedSpeakers: Int, device: String = "cpu", speakerModel: String = "compact") async throws -> [TranscriptSegment] {
        guard !samples.isEmpty, samples.count <= 16_000 * 60,
              samples.allSatisfy({ $0.isFinite && abs($0) <= 1.01 }) else { throw speechError("Invalid transcription audio chunk.") }
        let url = try folder().appendingPathComponent("\(UUID().uuidString).pcm")
        try samples.withUnsafeBytes { try Data($0).write(to: url, options: .atomic) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try await request("transcribe-chunk", ["path": url.path, "model": model, "jobID": jobID, "separateSpeakers": separateSpeakers, "expectedSpeakers": expectedSpeakers, "device": device, "speakerModel": speakerModel])
        struct Response: Decodable { var segments: [Segment]; var acceleration: AccelerationResult? }
        struct Segment: Decodable { var start: Double; var end: Double; var text: String; var speaker: String?; var speakerEmbedding: [Double]? }
        let result = try JSONDecoder().decode(Response.self, from: data)
        accelerationStatus = result.acceleration?.detail ?? "No recognition performed"
        return try result.segments.map {
            guard $0.start.isFinite, $0.end.isFinite, $0.start >= 0, $0.end >= $0.start,
                  $0.end <= Double(samples.count) / 16_000 + 0.1 else { throw speechError("The model returned invalid caption timing.") }
            if let vector = $0.speakerEmbedding { guard vector.count <= 4096, vector.allSatisfy({ $0.isFinite }) else { throw speechError("Invalid speaker voice example.") } }
            return TranscriptSegment(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker, speakerEmbedding: $0.speakerEmbedding)
        }
    }
    func diarizationInstalled(model: String = "compact") async throws -> Bool {
        struct Response: Decodable { var installed: Bool }
        return try JSONDecoder().decode(Response.self, from: await request("diarization-status", ["speakerModel": model])).installed
    }
    func speakerModels() async throws -> [SpeakerModelOption] { try JSONDecoder().decode([SpeakerModelOption].self, from: await request("speaker-models")) }
    func installDiarization(model: String = "compact") async throws { _ = try await request("install-diarization", ["speakerModel": model]) }
    func resetTranscription(jobID: String) async throws { _ = try await request("reset-transcription", ["jobID": jobID]) }
    // The file-transcription controller has its own service instance. Cancel it
    // synchronously before accepting a replacement job, so a delayed cancellation
    // handler cannot terminate that replacement's request.
    func cancelPendingOperations() {
        if !pending.isEmpty { failService("Speech operation cancelled.") }
    }
    func models() async throws -> [LocalModel] { try JSONDecoder().decode([LocalModel].self, from: await request("list")) }
    func install(_ id: String) async throws { status = "Installing model…"; _ = try await request("install", ["model": id]); status = "Model installed" }
    func remove(_ id: String) async throws { _ = try await request("remove", ["model": id]); status = "Model removed" }
    struct PreparedSpeech {
        let url: URL
        let timing: SpeechTiming
        let model: String
        func dispose() { try? FileManager.default.removeItem(at: url) }
    }
    func speak(_ text: String, model: String, voice: String, rate: Double) async throws {
        setRate(rate)
        let prepared = try await prepareSpeech(text, model: model, voice: voice)
        defer { prepared.dispose() }
        try await playPrepared(prepared, rate: Double(self.rate), paused: wantsPause)
    }
    func prepareSpeech(_ text: String, model: String, voice: String) async throws -> PreparedSpeech {
        stopSpeaking(); let token = generation; status = "Preparing speech…"
        preparing = true; preparationStarted = Date()
        let startedAt = ProcessInfo.processInfo.systemUptime
        if timingModel != model { timing = nil }; timingModel = model
        defer { if generation == token { preparing = false; preparationStarted = nil } }
        let url: URL
        if model == "system" { url = try await renderSystem(text, voice: voice, token: token) }
        else {
            preparingServiceSpeech = true
            let data: Data
            do { data = try await request("synthesize", ["text": text, "model": model, "voice": voice]) }
            catch { if generation == token { preparingServiceSpeech = false }; throw error }
            if generation == token { preparingServiceSpeech = false }
            let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            guard let path = result["path"] as? String else { throw speechError("The speech service returned no audio.") }; url = URL(fileURLWithPath: path)
        }
        do {
            guard generation == token else { throw CancellationError() }
            try Task.checkCancellation()
            let file = try AVAudioFile(forReading: url)
            let timing = SpeechTiming(preparation: ProcessInfo.processInfo.systemUptime - startedAt,
                                      audioDuration: Double(file.length) / file.processingFormat.sampleRate)
            return PreparedSpeech(url: url, timing: timing, model: model)
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    func playPrepared(_ prepared: PreparedSpeech, rate: Double, paused: Bool = false) async throws {
        stopSpeaking(); let token = generation; setRate(rate); wantsPause = paused
        try Task.checkCancellation()
        let audio = try AVAudioPlayer(contentsOf: prepared.url)
        audio.enableRate = true; audio.rate = self.rate; audio.delegate = self; player = audio
        timing = prepared.timing; timingModel = prepared.model
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                playback = continuation; status = wantsPause ? "Paused" : "Starting playback…"
                if !wantsPause { startPlayback(audio, token: token) }
            }
        }, onCancel: { Task { @MainActor [weak self] in
            guard let self, self.generation == token else { return }; self.stopSpeaking()
        } })
    }
    private var renderContinuation: CheckedContinuation<URL, Error>?
    private var renderFile: AVAudioFile?
    private var renderURL: URL?
    private var renderTimeout: Task<Void, Never>?
    private func renderSystem(_ text: String, voice: String, token: UUID) async throws -> URL {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw speechError("Select some text to read.") }
        let url = try folder().appendingPathComponent("\(UUID().uuidString).caf"); renderURL = url
        let synth = AVSpeechSynthesizer(); synthesizer = synth
        let utterance = AVSpeechUtterance(string: text)
        if !voice.isEmpty && voice != "af_heart" {
            guard let selected = AVSpeechSynthesisVoice(identifier: voice) else { throw speechError("This Mac voice is no longer available. Choose another voice in Settings.") }
            utterance.voice = selected
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                renderContinuation = continuation
                renderTimeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled, let self, self.generation == token, self.renderContinuation != nil else { return }
                    let c = self.renderContinuation; self.renderContinuation = nil
                    self.stopSpeaking(); c?.resume(throwing: speechError("The system voice did not produce audio. Choose an installed local voice model or check macOS voice availability."))
                }
                synth.write(utterance) { [weak self] buffer in
                    guard let incoming = buffer as? AVAudioPCMBuffer else { return }
                    // The synthesizer owns its callback buffer; copy every channel before returning.
                    guard let pcm = AVAudioPCMBuffer(pcmFormat: incoming.format, frameCapacity: max(1, incoming.frameLength)) else {
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == token else { return }
                            let c = self.renderContinuation; self.renderContinuation = nil
                            self.stopSpeaking(); c?.resume(throwing: speechError("Could not allocate system speech audio."))
                        }
                        return
                    }
                    pcm.frameLength = incoming.frameLength
                    let source = UnsafeMutableAudioBufferListPointer(incoming.mutableAudioBufferList)
                    let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
                    for (from, to) in zip(source, destination) {
                        if let sourceData = from.mData, let destinationData = to.mData, from.mDataByteSize > 0 {
                            memcpy(destinationData, sourceData, Int(from.mDataByteSize))
                        }
                    }
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.renderContinuation != nil else { return }
                        do {
                            if pcm.frameLength == 0 {
                                self.renderFile = nil; self.renderURL = nil; self.synthesizer = nil; self.renderTimeout?.cancel(); self.renderTimeout = nil
                                let c = self.renderContinuation; self.renderContinuation = nil; c?.resume(returning: url)
                            } else {
                                if self.renderFile == nil { self.renderFile = try AVAudioFile(forWriting: url, settings: pcm.format.settings) }
                                try self.renderFile?.write(from: pcm)
                            }
                        } catch {
                            let c = self.renderContinuation; self.renderContinuation = nil
                            self.stopSpeaking(); c?.resume(throwing: error)
                        }
                    }
                }
            }
        }, onCancel: { Task { @MainActor [weak self] in
            guard let self, self.generation == token else { return }; self.stopSpeaking()
        } })
    }
    private func startPlayback(_ audio: AVAudioPlayer, token: UUID) {
        playbackStartTimeout?.cancel(); playbackPermit?.cancel()
        let permit = PlaybackPermit(); playbackPermit = permit
        playbackStartTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.generation == token, self.player === audio else { return }
            let continuation = self.playback; self.playback = nil
            self.stopSpeaking()
            continuation?.resume(throwing: speechError("The audio output did not respond. Check your Mac’s output device and try again."))
        }
        audioQueue.async { [weak self] in
            guard permit.active else { return }
            let started = audio.play()
            guard permit.active else { audio.stop(); return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.generation == token, self.player === audio else { self.audioQueue.async { audio.stop() }; return }
                self.playbackStartTimeout?.cancel(); self.playbackStartTimeout = nil
                if !started {
                    self.player = nil; let continuation = self.playback; self.playback = nil
                    continuation?.resume(throwing: speechError("Audio playback could not start."))
                } else if self.wantsPause { self.audioQueue.async { audio.pause() }; self.status = "Paused" }
                else { self.status = "Reading" }
            }
        }
    }
    func setRate(_ value: Double) {
        rate = Float(max(0.5, min(2, value)))
        if let player { let value = rate; audioQueue.async { player.rate = value } }
    }
    func pause() { wantsPause = true; if let player { audioQueue.async { player.pause() } }; status = "Paused" }
    func resume() {
        wantsPause = false
        guard let player else { return }
        status = "Starting playback…"; startPlayback(player, token: generation)
    }
    func stopSpeaking() {
        generation = UUID(); preparing = false; preparationStarted = nil; wantsPause = false; if let player { audioQueue.async { player.stop() } }; player = nil
        playbackStartTimeout?.cancel(); playbackStartTimeout = nil; playbackPermit?.cancel(); playbackPermit = nil
        if preparingServiceSpeech { preparingServiceSpeech = false; failService("Speech preparation cancelled.") }
        renderTimeout?.cancel(); renderTimeout = nil
        synthesizer?.stopSpeaking(at: .immediate); synthesizer = nil; renderFile = nil
        if let url = renderURL { try? FileManager.default.removeItem(at: url) }; renderURL = nil
        let c = playback; playback = nil; c?.resume(throwing: CancellationError())
        let r = renderContinuation; renderContinuation = nil; r?.resume(throwing: CancellationError()); status = "Ready"
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }; self.player = nil
            let c = self.playback; self.playback = nil; self.status = "Ready"
            if flag { c?.resume() } else { c?.resume(throwing: speechError("Audio playback ended unexpectedly.")) }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }; self.player = nil
            let c = self.playback; self.playback = nil; c?.resume(throwing: error ?? speechError("The audio could not be decoded."))
        }
    }
    func startRecording() async throws {
        guard !recording else { return }
        cancelRecording(); history.reset(); let token = recordingGeneration
        status = "Starting microphone…"
        defer { if recordingGeneration == token && !recording { status = "Ready" } }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw speechError("Allow Microphone access in System Settings → Privacy & Security → Microphone.") }
        try Task.checkCancellation()
        guard recordingGeneration == token else { throw CancellationError() }
        let url = try folder().appendingPathComponent("\(UUID().uuidString).wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false]
        let audio = try AVAudioRecorder(url: url, settings: settings); audio.isMeteringEnabled = true
        guard audio.record() else { throw speechError("The microphone could not start recording. Check the selected audio input.") }
        recorder = audio; recordingURL = url; recordingStarted = Date(); recording = true; status = "Listening"
        meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in
            guard let self, let recorder = self.recorder else { return }; recorder.updateMeters(); self.level = min(1, Double(pow(10, recorder.averagePower(forChannel: 0) / 20)) * 4); self.history.append(self.level)
            if Date().timeIntervalSince(self.recordingStarted ?? Date()) >= 300 { recorder.pause(); self.level = 0; self.status = "Five-minute limit reached. Finish dictation to transcribe." }
        } }
    }
    func finishRecording(model: String, device: String = "cpu") async throws -> String {
        guard let url = recordingURL else { throw speechError("Start recording before transcribing.") }
        recorder?.stop(); recorder = nil; meter?.invalidate(); meter = nil; recording = false; level = 0; recordingURL = nil
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1, file.length > 0, file.length <= 16000 * 300 + 4096 else { throw speechError("Recording is empty or has an unsupported format.") }
        let frames = AVAudioFrameCount(min(file.length, 16000 * 300))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { throw speechError("Could not allocate recording memory.") }
        try file.read(into: buffer, frameCount: frames)
        guard let samples = buffer.floatChannelData?[0] else { throw speechError("Could not read microphone audio.") }
        let pcm = try folder().appendingPathComponent("\(UUID().uuidString).f32")
        try Data(bytes: samples, count: Int(buffer.frameLength) * 4).write(to: pcm); defer { try? FileManager.default.removeItem(at: pcm) }
        status = "Transcribing locally…"
        let data = try await request("transcribe", ["model": model, "path": pcm.path, "device": device]); status = "Ready"
        struct Response: Decodable { var text: String; var acceleration: AccelerationResult? }
        let result = try JSONDecoder().decode(Response.self, from: data)
        accelerationStatus = result.acceleration?.detail ?? ""
        return result.text
    }
    func cancelRecording() { recordingGeneration = UUID(); status = "Ready"; recorder?.stop(); recorder = nil; meter?.invalidate(); meter = nil; recording = false; level = 0; if let url = recordingURL { try? FileManager.default.removeItem(at: url) }; recordingURL = nil }
    func rewrite(_ text: String) async throws -> String {
        status = "Suggesting wording…"
        defer { status = "Ready" }
        let data = try await request("rewrite", ["text": text])
        return (try JSONSerialization.jsonObject(with: data) as? [String: String])?["text"] ?? ""
    }
    func shutdown() { stopSpeaking(); cancelRecording(); failService("Speech service closed."); if let session { try? FileManager.default.removeItem(at: session) }; session = nil }
}
