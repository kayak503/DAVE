import Foundation

@main struct InteractionTests {
    @MainActor static func main() async throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
        var history = LevelHistory()
        history.append(1); history.append(0.2)
        check(history.samples[46] == 1 && history.samples[47] == 0.2, "loud sample must move left while new sample enters right")
        check(history.samples.prefix(46).allSatisfy { $0 == 0 }, "history must not animate all bars with current input")
        for _ in 0..<48 { history.append(0) }
        check(history.samples.count == 48 && history.samples.allSatisfy { $0 == 0 }, "old peak must leave bounded history")
        history.append(.nan); history.append(9); check(history.samples.suffix(2) == [0,1], "meter must remain finite and bounded")
        history.reset(); check(history.samples.allSatisfy { $0 == 0 }, "new recording resets history")
        let slow = SpeechTiming(preparation: 4, audioDuration: 6)
        check(slow.capacity == 1.5 && slow.isSlower(than: 2) && !slow.isSlower(than: 1), "warning must follow measured generation versus current rate")
        check(SpeechTiming(preparation: 0.5, audioDuration: 5).capacity == 10, "capacity calculation")
        var toast = ToastCountdown(); toast.start(seconds: 5, now: 10)
        toast.tick(now: 12, paused: false); check(toast.remaining == 3, "toast elapsed")
        toast.tick(now: 112, paused: true); check(toast.remaining == 3, "hover freezes lifetime")
        toast.tick(now: 113, paused: false); check(toast.remaining == 2, "unhover resumes remaining lifetime")
        toast.start(seconds: 8, now: 113); check(toast.fraction == 1, "replacement toast resets lifetime")
        toast.tick(now: 122, paused: false); check(toast.remaining == 0 && toast.fraction == 0, "toast expires without dismiss click")
        for key: UInt16 in [36,76] {
            check(DictationDeliveryPolicy.isFinishKey(key, modifiers: 0, recording: true, capturingShortcut: false), "Enter ends recording")
            check(!DictationDeliveryPolicy.isFinishKey(key, modifiers: 0, recording: false, capturingShortcut: false), "Enter outside recording remains untouched")
            check(!DictationDeliveryPolicy.isFinishKey(key, modifiers: 0x100000, recording: true, capturingShortcut: false), "modified Enter remains untouched")
            check(!DictationDeliveryPolicy.isFinishKey(key, modifiers: 0, recording: true, capturingShortcut: true), "shortcut recorder owns keys")
        }
        check(!DictationDeliveryPolicy.shouldInsert(external: true, capturedTarget: false), "no focus must use clipboard")
        check(DictationDeliveryPolicy.shouldInsert(external: true, capturedTarget: true), "valid original target can insert")
        check(!DictationDeliveryPolicy.shouldInsert(external: false, capturedTarget: true), "in-app dictation never inserts externally")
        check(ReadingControls.speeds.map(ReadingControls.nextSpeed) == [1, 1.2, 1.5, 2, 0.5], "cycle every preset and wrap")
        check(ReadingControls.nextSpeed(1.3) == 1.5, "old custom speeds advance to next preset")
        var generated: [Int] = [], disposed: [Int] = []
        let buffer = ReadingBuffer<Int>(prepare: { i in generated.append(i); return i }, dispose: { disposed.append($0) })
        buffer.fill(from: 0, count: 20, ahead: 5)
        let first = try await buffer.value(at: 0)
        check(first == 0, "first sentence available")
        let fifth = try await buffer.value(at: 5)
        check(fifth == 5 && generated == Array(0...5), "five ahead generated without waiting for playback")
        buffer.fill(from: 3, count: 20, ahead: 5)
        let reused = try await buffer.value(at: 3)
        _ = try await buffer.value(at: 8)
        check(reused == 3 && generated == Array(0...8), "seek reuses prepared sentence")
        buffer.fill(from: 19, count: 20, ahead: 10)
        _ = try await buffer.value(at: 19)
        check(generated.last == 19 && !generated.contains(20), "stop at document boundary")
        buffer.cancel()
        for _ in 0..<100 { await Task.yield() }
        check(Set(disposed) == Set(generated) && disposed.count == generated.count, "every evicted artifact disposed exactly once")
        var started = false, cancelled = false
        let slowBuffer = ReadingBuffer<Int>(prepare: { _ in
            started = true
            do { try await Task.sleep(for: .seconds(30)); return 1 }
            catch { cancelled = true; throw error }
        }, dispose: { _ in fatalError("cancelled producer should not produce a value") })
        slowBuffer.fill(from: 0, count: 100, ahead: 3)
        while !started { await Task.yield() }
        slowBuffer.cancel()
        for _ in 0..<100 { await Task.yield() }
        check(cancelled && slowBuffer.readyCount == 0, "stop cancels running and queued generation")
        var clipboard = "", order: [String] = []
        let delivered = DictationDelivery.deliver("Keep this transcript", shouldInsert: true, copy: {
            clipboard = $0; order.append("copy"); return true
        }, insert: { _ in order.append("insert") })
        check(clipboard == "Keep this transcript" && order == ["copy", "insert"], "clipboard precedes even falsely successful insertion")
        check(delivered.copied && delivered.insertionAccepted && delivered.message.contains("Command-V"), "success still offers manual paste")
        let rejected = DictationDelivery.deliver("Fallback text", shouldInsert: true, copy: { clipboard = $0; return true }, insert: { _ in throw CancellationError() })
        check(clipboard == "Fallback text" && rejected.copied && !rejected.insertionAccepted, "rejected field keeps clipboard")
        let inApp = DictationDelivery.deliver("In-app draft", shouldInsert: false, copy: { clipboard = $0; return true }, insert: { _ in fatalError("unexpected insertion") })
        check(inApp.copied && clipboard == "In-app draft", "in-app dictation also copied")
        let unavailable = DictationDelivery.deliver("Draft", shouldInsert: false, copy: { _ in false }, insert: { _ in })
        check(!unavailable.copied && unavailable.message.contains("Dictate"), "clipboard failures not reported as success")
        check(!TranscriptionModelGuidance.recommendedForGroups("whisper-tiny"), "Tiny is not recommended for group recordings")
        check(!TranscriptionModelGuidance.recommendedForGroups("whisper-base"), "Base is not recommended for group recordings")
        for id in ["whisper-small", "whisper-medium", "whisper-large-turbo"] {
            check(TranscriptionModelGuidance.recommendedForGroups(id), "Small and higher tiers recommended")
        }
        print("NATIVE_INTERACTION_OK")
    }
}
