import Foundation

struct LevelHistory {
    private(set) var samples = Array(repeating: 0.0, count: 48)
    mutating func append(_ level: Double) {
        samples.removeFirst()
        samples.append(level.isFinite ? min(1, max(0, level)) : 0)
    }
    mutating func reset() { samples = Array(repeating: 0, count: 48) }
}

struct SpeechTiming {
    let preparation: Double
    let audioDuration: Double
    var capacity: Double { audioDuration / max(0.001, preparation) }
    func isSlower(than rate: Double) -> Bool { preparation > 0 && audioDuration > 0 && capacity < rate }
}

struct ToastCountdown {
    private(set) var remaining: Double = 0
    private(set) var duration: Double = 1
    private var lastTick: Double = 0
    var fraction: Double { max(0, min(1, remaining / duration)) }
    mutating func start(seconds: Double, now: Double) { duration = max(0.1, seconds); remaining = duration; lastTick = now }
    mutating func tick(now: Double, paused: Bool) {
        if !paused { remaining = max(0, remaining - max(0, now - lastTick)) }
        lastTick = now
    }
}

enum DictationDeliveryPolicy {
    static func shouldInsert(external: Bool, capturedTarget: Bool) -> Bool { external && capturedTarget }
    static func isFinishKey(_ key: UInt16, modifiers: UInt64, recording: Bool, capturingShortcut: Bool) -> Bool {
        recording && !capturingShortcut && modifiers & 0x1e0000 == 0 && (key == 36 || key == 76)
    }
}

enum ReadingControls {
    static let speeds = [0.5, 1.0, 1.2, 1.5, 2.0]
    static func nextSpeed(_ rate: Double) -> Double {
        speeds.first { $0 > rate + 0.001 } ?? speeds[0]
    }
}

// A single producer prepares current + lookahead sentences. Completed entries
// survive seeks within the window; evicted audio is disposed even after cancellation.
@MainActor final class ReadingBuffer<Value> {
    private var tasks: [Int: Task<Value, Error>] = [:]
    private var tail: Task<Value, Error>?
    private var ready = Set<Int>()
    var onChange: (() -> Void)?
    var readyCount: Int { ready.count }
    private let prepare: (Int) async throws -> Value
    private let dispose: (Value) -> Void
    init(prepare: @escaping (Int) async throws -> Value, dispose: @escaping (Value) -> Void) {
        self.prepare = prepare; self.dispose = dispose
    }
    func fill(from index: Int, count: Int, ahead: Int) {
        let desired = Set(index..<min(count, index + max(3, min(10, ahead)) + 1))
        for key in Array(tasks.keys) where !desired.contains(key) { remove(key) }
        for key in desired.sorted() where tasks[key] == nil {
            let previous = tail
            let prepare = self.prepare
            let task = Task { @MainActor [weak self] in
                if let previous { _ = await previous.result }
                try Task.checkCancellation()
                let value = try await prepare(key)
                // Return ownership even if cancelled: eviction will dispose it.
                if !Task.isCancelled { self?.ready.insert(key); self?.onChange?() }
                return value
            }
            tasks[key] = task; tail = task
        }
        onChange?()
    }
    func value(at index: Int) async throws -> Value {
        guard let task = tasks[index] else { throw CancellationError() }
        let value = try await task.value
        try Task.checkCancellation()
        return value
    }
    private func remove(_ key: Int) {
        guard let task = tasks.removeValue(forKey: key) else { return }
        ready.remove(key); task.cancel()
        let dispose = self.dispose
        Task { if case .success(let value) = await task.result { dispose(value) } }
    }
    func cancel() {
        for key in Array(tasks.keys) { remove(key) }
        tail = nil; onChange?()
    }
}

struct DictationDelivery {
    let copied: Bool
    let insertionAccepted: Bool
    static func deliver(_ text: String, shouldInsert: Bool,
                        copy: (String) -> Bool, insert: (String) throws -> Void) -> DictationDelivery {
        // Preserve the transcript even when an app falsely reports AX insertion success.
        let copied = copy(text)
        var accepted = false
        if shouldInsert { do { try insert(text); accepted = true } catch {} }
        return DictationDelivery(copied: copied, insertionAccepted: accepted)
    }
    var message: String {
        if !copied { return "Couldn’t copy the transcript. It is available in Dictate." }
        if insertionAccepted { return "Transcript copied; insertion requested. If it didn’t appear, press Command-V." }
        return "Transcript copied. Press Command-V to paste it where you need it."
    }
}


enum TranscriptionModelGuidance {
    static func recommendedForGroups(_ id: String) -> Bool {
        ["whisper-small", "whisper-medium", "whisper-large-turbo"].contains(id)
    }
    static func detail(_ id: String) -> String {
        switch id {
        case "whisper-tiny": return "Tiny: fastest for short, clear solo dictation. Can miss words in multi-person recordings."
        case "whisper-base": return "Base: a lightweight step up for clear speech. For meetings, prefer Small or above."
        case "whisper-small": return "Small: recommended starting point for multi-person recordings; balances recognition quality and CPU time."
        case "whisper-medium": return "Medium: higher-capacity English recognition for detailed recordings. Allow more memory and processing time."
        case "whisper-large-turbo": return "Large v3 Turbo: highest-capacity recognition option here. Best suited to Macs with more memory; processing speed varies by hardware."
        default: return "Recognition quality depends on the recording. Speaker detection is separate from speech recognition."
        }
    }
}
