import AppKit
import ApplicationServices

@main struct SystemTests {
    @MainActor static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fatalError(message) }
        }
        let modifiers: [UInt64] = [1 << 20, 1 << 19, 1 << 18, 1 << 17]
        for subset in 1..<16 {
            let selected = modifiers.enumerated().filter { subset & (1 << $0.offset) != 0 }.map(\.element)
            let generic = selected.reduce(0, |)
            let active = ShortcutMatcher.sides.filter { generic & $0.0 != 0 }
            let left = active.reduce(generic) { $0 | $1.1 }
            let right = active.reduce(generic) { $0 | $1.2 }
            let either = Shortcut(keyCode: 12, modifiers: generic)
            let lhs = Shortcut(keyCode: 12, modifiers: generic, side: "left")
            let rhs = Shortcut(keyCode: 12, modifiers: generic, side: "right")
            check(ShortcutMatcher.matches(either, keyCode: 12, flags: left), "generic left subset \(subset)")
            check(ShortcutMatcher.matches(either, keyCode: 12, flags: right), "generic right subset \(subset)")
            check(ShortcutMatcher.matches(lhs, keyCode: 12, flags: left), "left subset \(subset)")
            check(!ShortcutMatcher.matches(lhs, keyCode: 12, flags: right), "left must reject right")
            check(ShortcutMatcher.matches(rhs, keyCode: 12, flags: right), "right subset \(subset)")
            check(!ShortcutMatcher.matches(rhs, keyCode: 12, flags: left), "right must reject left")
            check(!ShortcutMatcher.matches(lhs, keyCode: 12, flags: left | right), "both sides must not match exact side")
            check(!ShortcutMatcher.matches(lhs, keyCode: 12, flags: generic), "unknown side must not match")
            check(!ShortcutMatcher.matches(either, keyCode: 13, flags: left), "different key")
            check(!ShortcutMatcher.matches(either, keyCode: 12, flags: 0), "missing modifiers")
            check(ShortcutMatcher.side(flags: left) == "left", "record left")
            check(ShortcutMatcher.side(flags: right) == "right", "record right")
            check(ShortcutMatcher.side(flags: generic) == "either", "record unknown")
            if let missing = modifiers.first(where: { generic & $0 == 0 }) {
                check(!ShortcutMatcher.matches(either, keyCode: 12, flags: left | missing), "extra modifier")
            }
        }
        for key: UInt16 in [36, 76] {
            check(DictationDeliveryPolicy.isFinishKey(key, modifiers: 0, recording: true, capturingShortcut: false), "Enter must finish active recording")
            check(!DictationDeliveryPolicy.isFinishKey(key, modifiers: 0, recording: false, capturingShortcut: false), "idle Enter must not be swallowed")
        }
        var state = ShortcutKeyState()
        check(state.process(key: 12, keyUp: false, capturing: false, matches: true, repeated: false) == .fire, "first press fires")
        check(state.process(key: 12, keyUp: false, capturing: false, matches: true, repeated: true) == .consume, "repeat consumed once")
        check(state.process(key: 12, keyUp: false, capturing: false, matches: false, repeated: true) == .consume, "held shortcut stays consumed after modifier release")
        check(state.process(key: 12, keyUp: true, capturing: false, matches: false, repeated: false) == .consume, "paired release consumed")
        check(state.process(key: 12, keyUp: false, capturing: false, matches: false, repeated: false) == .pass, "unmatched opposite side passes")
        check(state.process(key: 12, keyUp: false, capturing: true, matches: true, repeated: false) == .pass, "recorder bypass")
        check(state.process(key: 12, keyUp: false, capturing: false, matches: true, repeated: true) == .consume, "orphan repeat never fires")
        state.reset()
        check(state.process(key: 12, keyUp: false, capturing: false, matches: true, repeated: false) == .fire, "reset releases held state")
        let replaced = try AXTextEditing.replacement(value: "a😀bc", range: CFRange(location: 1, length: 2), text: "🐈")
        check(replaced.0 == "a🐈bc" && replaced.1 == 3, "UTF16 replacement preserves surrounding text and cursor")
        let inserted = try AXTextEditing.replacement(value: "abc", range: CFRange(location: 3, length: 0), text: "d")
        check(inserted.0 == "abcd" && inserted.1 == 4, "caret insertion")
        for invalid in [CFRange(location: -1, length: 0), CFRange(location: 5, length: 1), CFRange(location: 0, length: Int.max), CFRange(location: 2, length: 1)] {
            do { _ = try AXTextEditing.replacement(value: "a😀bc", range: invalid, text: "x"); fatalError("invalid range accepted") }
            catch { check(error.localizedDescription.contains("invalid text selection"), "range rejection") }
        }
        do { _ = try AXTextEditing.bounded(String(repeating: "x", count: AXTextEditing.limit + 1)); fatalError("oversized text accepted") }
        catch { check(error.localizedDescription.contains("safety limit"), "size bound") }
        _ = NSApplication.shared
        let button = RecorderButton(frame: .zero)
        check(button.isAccessibilityElement(), "recorder is an AX element")
        check(button.accessibilityRole() == .button, "recorder AX button role")
        check(button.accessibilityLabel() == "Record keyboard shortcut", "recorder AX label")
        check(button.accessibilityValue() as? String == button.shortcut.display, "recorder AX shortcut value")
        check(button.accessibilityPerformPress(), "recorder supports AX press")
        check(button.recording && GlobalHotkeys.capturing, "AX press enters capture")
        check((button.accessibilityValue() as? String)?.contains("Recording") == true, "capture state accessible")
        button.finish()
        check(!button.recording && !GlobalHotkeys.capturing, "AX capture cancellation")
        check(button.accessibilityValue() as? String == button.shortcut.display, "AX value restored")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        let rich = NSPasteboardItem()
        rich.setString("original text", forType: .string)
        rich.setData(Data("{\\rtf1\\ansi original text}".utf8), forType: .rtf)
        board.writeObjects([rich])
        let snapshot = try ClipboardSnapshot(board: board)
        board.clearContents(); board.setString("selected passage", forType: .string)
        let copied = board.changeCount
        snapshot.restore(board: board, ifVersion: copied)
        check(board.string(forType: .string) == "original text", "clipboard text restored")
        check(board.data(forType: .rtf) == Data("{\\rtf1\\ansi original text}".utf8), "rich clipboard representation restored")
        board.clearContents(); board.setString("new user copy", forType: .string)
        snapshot.restore(board: board, ifVersion: copied)
        check(board.string(forType: .string) == "new user copy", "later clipboard change preserved")
        board.clearContents()
        let empty = try ClipboardSnapshot(board: board)
        board.setString("temporary selection", forType: .string)
        empty.restore(board: board, ifVersion: board.changeCount)
        check(board.string(forType: .string) == nil, "empty clipboard restored")
        let denied = AccessibilityProbe(trusted: false, canPostEvents: false, focusedApplicationError: AXError.apiDisabled.rawValue)
        let allowed = AccessibilityProbe(trusted: true, canPostEvents: true, focusedApplicationError: 0)
        check(denied.explanation(fresh: allowed, shortcutsActive: false).contains("fresh process"), "stale process permission distinguished")
        check(denied.explanation(fresh: denied, shortcutsActive: false).contains("denies"), "actual denial retained")
        check(allowed.explanation(fresh: allowed, shortcutsActive: true).contains("verified"), "permission and tap verified")
        check(allowed.explanation(fresh: allowed, shortcutsActive: false).contains("could not register"), "tap failure not passed")
        let disabled = AccessibilityProbe(trusted: true, canPostEvents: true, focusedApplicationError: AXError.apiDisabled.rawValue)
        check(disabled.explanation(fresh: allowed, shortcutsActive: true).contains("API is disabled"), "API denial overrides trust flag")
        let ax = MacAccessibility()
        check(ax.trusted == AXIsProcessTrusted(), "current-process trust")
        ax.clearTarget()
        do { try ax.insert("must not insert"); fatalError("empty target accepted") }
        catch { check(error.localizedDescription.contains("No dictation target"), "specific missing target error") }
        let hotkeys = GlobalHotkeys()
        do {
            try hotkeys.apply(read: Shortcut(keyCode: 12, modifiers: 1 << 19), dictate: Shortcut(keyCode: 12, modifiers: 1 << 19))
            fatalError("conflicting bindings accepted")
        } catch { check(error.localizedDescription.contains("overlap"), "conflict classified before permission") }
        if !ax.trusted {
            do { try ax.captureTarget(); fatalError("AX untrusted capture accepted") }
            catch { check(error.localizedDescription.contains("Enable Accessibility"), "real AX denial") }
            do { try hotkeys.apply(read: Shortcut(keyCode: 12, modifiers: 1 << 19), dictate: Shortcut(keyCode: 13, modifiers: 1 << 19)); fatalError("untrusted hotkeys accepted") }
            catch { check(error.localizedDescription.contains("Enable Accessibility"), "real event tap denial") }
            print("API probe: this process is untrusted; permission errors verified without changing permissions.")
        } else { print("API probe: current process trusted; no live keyboard registrations or text mutations performed.") }
        hotkeys.stop()
        print("NATIVE_SYSTEM_OK")
    }
}
