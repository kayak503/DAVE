import AppKit
import ApplicationServices
import SwiftUI

struct MacSystemError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// AX ranges count UTF-16 code units, not Swift Characters.
struct AXTextEditing {
    static let limit = 1_000_000
    static func bounded(_ text: String) throws -> String {
        guard text.utf16.count <= limit else { throw MacSystemError(message: "The text exceeds the one-million-character safety limit. Select a smaller passage.") }
        return text
    }
    static func replacement(value: String, range: CFRange, text: String) throws -> (String, Int) {
        _ = try bounded(value); _ = try bounded(text)
        let units = Array(value.utf16)
        let count = units.count
        func boundary(_ offset: Int) -> Bool {
            offset == 0 || offset == count || !(0xDC00...0xDFFF).contains(units[offset]) || !(0xD800...0xDBFF).contains(units[offset - 1])
        }
        guard range.location >= 0, range.length >= 0, range.location <= count, range.length <= count - range.location,
              boundary(range.location), boundary(range.location + range.length),
              let swiftRange = Range(NSRange(location: range.location, length: range.length), in: value) else {
            throw MacSystemError(message: "The destination app returned an invalid text selection. Use Copy to paste the transcript yourself.")
        }
        var result = value; result.replaceSubrange(swiftRange, with: text)
        return (try bounded(result), range.location + text.utf16.count)
    }
}

@MainActor struct ClipboardSnapshot {
    let version: Int
    private let items: [NSPasteboardItem]
    init(board: NSPasteboard) throws {
        version = board.changeCount
        var copies: [NSPasteboardItem] = [], bytes = 0
        for item in board.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else { throw MacSystemError(message: "The clipboard could not be preserved.") }
                bytes += data.count
                guard bytes <= 20_000_000 else { throw MacSystemError(message: "The clipboard is too large to preserve. Use Paste Text instead.") }
                copy.setData(data, forType: type)
            }
            copies.append(copy)
        }
        guard board.changeCount == version else { throw MacSystemError(message: "The clipboard changed while reading it.") }
        items = copies
    }
    func restore(board: NSPasteboard, ifVersion version: Int) {
        guard board.changeCount == version else { return }
        board.clearContents()
        if !items.isEmpty { board.writeObjects(items) }
    }
}

@MainActor final class MacAccessibility {
    private var target: AXUIElement?
    var trusted: Bool { AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary) }
    func request() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    private func requireTrust() throws {
        guard trusted else { throw MacSystemError(message: "Enable Accessibility for DAVE in System Settings, then try again.") }
    }
    private func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success, let value else { throw MacSystemError(message: "The focused app could not provide \(name) (Accessibility error \(error.rawValue)). Select a supported text field and try again.") }
        return value
    }
    private func element(_ value: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private func focused() throws -> AXUIElement {
        try requireTrust()
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1.5)
        if let appValue = try? attribute(system, kAXFocusedApplicationAttribute), let app = element(appValue) {
            AXUIElementSetMessagingTimeout(app, 1.5)
            // Chromium/Electron conventions set through the public AX API; unsupported attributes are harmless.
            _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        guard let focused = element(try attribute(system, kAXFocusedUIElementAttribute)) else { throw MacSystemError(message: "The focused app did not provide a text field.") }
        AXUIElementSetMessagingTimeout(focused, 1.5)
        return focused
    }
    private func rejectSecure(_ focused: AXUIElement) throws {
        var current = focused
        var visited: [AXUIElement] = []
        for _ in 0..<32 {
            if visited.contains(where: { CFEqual($0, current) }) { break }
            visited.append(current)
            AXUIElementSetMessagingTimeout(current, 1.5)
            for name in [kAXRoleAttribute, kAXSubroleAttribute] {
                if let role = (try? attribute(current, name)) as? String,
                   role.localizedCaseInsensitiveContains("secure") || role.localizedCaseInsensitiveContains("password") {
                    throw MacSystemError(message: "Dictation and reading are unavailable in secure text fields.")
                }
            }
            guard let parentValue = try? attribute(current, kAXParentAttribute), let parent = element(parentValue) else { return }
            current = parent
        }
        throw MacSystemError(message: "The destination app returned an accessibility hierarchy that could not be verified. Use Copy instead.")
    }
    private func selectedRange(_ target: AXUIElement) throws -> (AXValue, CFRange) {
        let raw = try attribute(target, kAXSelectedTextRangeAttribute)
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { throw MacSystemError(message: "The destination app did not provide a valid text selection.") }
        let value = unsafeBitCast(raw, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length >= 0, range.length <= AXTextEditing.limit else {
            throw MacSystemError(message: "The destination app returned an invalid or oversized text selection.")
        }
        return (value, range)
    }
    private func writable(_ element: AXUIElement, _ name: String) -> Bool {
        var writable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &writable) == .success && writable.boolValue
    }
    // Read-only selection lookup: selected page text need not be an editable field.
    private func selection(in candidate: AXUIElement) throws -> String? {
        if let text = (try? attribute(candidate, kAXSelectedTextAttribute)) as? String, !text.isEmpty {
            try rejectSecure(candidate)
            return try AXTextEditing.bounded(text)
        }
        guard let (rangeValue, range) = try? selectedRange(candidate), range.length > 0 else { return nil }
        var raw: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(candidate, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &raw) == .success,
           let text = raw as? String, !text.isEmpty { try rejectSecure(candidate); return try AXTextEditing.bounded(text) }
        if let text = (try? attribute(candidate, kAXValueAttribute)) as? String,
           range.location <= text.utf16.count, range.length <= text.utf16.count - range.location,
           let bounds = Range(NSRange(location: range.location, length: range.length), in: text) {
            try rejectSecure(candidate); return try AXTextEditing.bounded(String(text[bounds]))
        }
        return nil
    }
    func selectedText() throws -> String {
        let focus = try focused()
        try rejectSecure(focus)
        var queue = [focus], visited: [AXUIElement] = []
        // Browsers may put the selection on a web area or focused element's ancestor.
        var parent = focus
        for _ in 0..<8 {
            guard let raw = try? attribute(parent, kAXParentAttribute), let next = element(raw), !queue.contains(where: { CFEqual($0, next) }) else { break }
            queue.append(next); parent = next
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var index = 0
        while index < queue.count, index < 256, ProcessInfo.processInfo.systemUptime < deadline {
            let candidate = queue[index]; index += 1
            if visited.contains(where: { CFEqual($0, candidate) }) { continue }
            visited.append(candidate); AXUIElementSetMessagingTimeout(candidate, 0.15)
            if let text = try selection(in: candidate) { return text }
            // Stay inside the focused window/page; never search other application windows.
            let role = (try? attribute(candidate, kAXRoleAttribute)) as? String
            if role == kAXApplicationRole || role == kAXSystemWideRole { continue }
            for name in [kAXSelectedChildrenAttribute, kAXChildrenAttribute] {
                if let children = (try? attribute(candidate, name)) as? [AXUIElement] {
                    queue.append(contentsOf: children.prefix(max(0, 256 - queue.count)))
                }
            }
        }
        throw MacSystemError(message: "No readable selection was found. Select text first; hovering alone does not select it. You can also copy the text and use Paste in Read.")
    }
    func selectedTextWithCopyFallback() async throws -> String {
        try requireTrust()
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw MacSystemError(message: "Select text in another app, then use the read shortcut. Inside DAVE, use Paste Text.")
        }
        // AXFocusedUIElement is optional here: many read-only browser views return
        // -25212 even though their normal Copy command works perfectly.
        if let focus = try? focused() { try rejectSecure(focus) }
        do { return try await copySelection(from: front.processIdentifier) }
        catch is CancellationError { throw CancellationError() }
        catch {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front.processIdentifier else {
                throw MacSystemError(message: "The active app changed while copying. Select the text and try again.")
            }
            if let text = try? selectedText() { return text }
            throw MacSystemError(message: "No selected text was copied. Highlight the passage and try again, or copy it and choose Paste Text in Read.")
        }
    }
    private func copySelection(from pid: pid_t) async throws -> String {
        let board = NSPasteboard.general
        let snapshot = try ClipboardSnapshot(board: board)
        guard board.changeCount == snapshot.version,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw MacSystemError(message: "The selection changed before it could be copied.")
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false) else {
            throw MacSystemError(message: "The Copy command could not be sent.")
        }
        // Send only Command-C, never Select All, and never require an editable field.
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(pid); up.postToPid(pid)
        for _ in 0..<60 {
            // Observe Copy before cancellation so an already-completed copy can be restored.
            if board.changeCount != snapshot.version {
                let copiedVersion = board.changeCount
                let text = board.string(forType: .string)
                snapshot.restore(board: board, ifVersion: copiedVersion)
                try Task.checkCancellation()
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MacSystemError(message: "The app did not copy a text selection.")
                }
                return try AXTextEditing.bounded(text)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw MacSystemError(message: "The app did not respond to Copy.")
    }
    func captureTarget() throws {
        target = nil
        let element = try focused()
        try rejectSecure(element)
        if !writable(element, kAXSelectedTextAttribute) {
            guard writable(element, kAXValueAttribute), let value = try attribute(element, kAXValueAttribute) as? String else {
                throw MacSystemError(message: "This field does not support direct text insertion. Use Copy and paste the transcript yourself.")
            }
            let (_, range) = try selectedRange(element)
            _ = try AXTextEditing.replacement(value: value, range: range, text: "")
        }
        target = element
    }
    func clearTarget() { target = nil }
    func insert(_ text: String) throws {
        guard let retained = target else { throw MacSystemError(message: "No dictation target is retained. Start dictation while the destination text field is focused, or use Copy.") }
        target = nil
        _ = try AXTextEditing.bounded(text)
        let current = try focused()
        guard CFEqual(retained, current) else { throw MacSystemError(message: "The focused field changed. Text was not inserted. Copy the transcript or start again in the destination field.") }
        try rejectSecure(retained)
        let result: AXError
        if writable(retained, kAXSelectedTextAttribute) {
            result = AXUIElementSetAttributeValue(retained, kAXSelectedTextAttribute as CFString, text as CFString)
        } else {
            guard writable(retained, kAXValueAttribute), let original = try attribute(retained, kAXValueAttribute) as? String else {
                throw MacSystemError(message: "The destination field no longer supports insertion. Use Copy instead.")
            }
            let (_, range) = try selectedRange(retained)
            let (replacement, cursor) = try AXTextEditing.replacement(value: original, range: range, text: text)
            // Revalidate the same element and snapshot immediately before replacing its value.
            let (_, latestRange) = try selectedRange(retained)
            guard CFEqual(retained, try focused()), (try attribute(retained, kAXValueAttribute) as? String) == original,
                  latestRange.location == range.location, latestRange.length == range.length else {
                throw MacSystemError(message: "The destination text or selection changed. Use Copy instead.")
            }
            result = AXUIElementSetAttributeValue(retained, kAXValueAttribute as CFString, replacement as CFString)
            if result == .success, writable(retained, kAXSelectedTextRangeAttribute) {
                var cursorRange = CFRange(location: cursor, length: 0)
                if let cursorValue = AXValueCreate(.cfRange, &cursorRange) {
                    _ = AXUIElementSetAttributeValue(retained, kAXSelectedTextRangeAttribute as CFString, cursorValue)
                }
            }
        }
        guard result == .success else { throw MacSystemError(message: "The destination app rejected text insertion (Accessibility error \(result.rawValue)). Use Copy to paste it yourself.") }
    }
}

// Device-specific bits are public NX_DEVICE modifier flags. Generic flags are NSEvent flags.
struct ShortcutMatcher {
    static let genericMask = NSEvent.ModifierFlags([.command, .option, .control, .shift]).rawValue
    static let sides: [(UInt64, UInt64, UInt64)] = [
        (UInt64(NSEvent.ModifierFlags.command.rawValue), 0x08, 0x10),
        (UInt64(NSEvent.ModifierFlags.option.rawValue), 0x20, 0x40),
        (UInt64(NSEvent.ModifierFlags.control.rawValue), 0x01, 0x2000),
        (UInt64(NSEvent.ModifierFlags.shift.rawValue), 0x02, 0x04)
    ]
    static func matches(_ shortcut: Shortcut, keyCode: UInt16, flags: UInt64) -> Bool {
        guard shortcut.keyCode == keyCode, flags & UInt64(genericMask) == shortcut.modifiers & UInt64(genericMask) else { return false }
        guard shortcut.side != "either" else { return true }
        return sides.filter { shortcut.modifiers & $0.0 != 0 }.allSatisfy { _, left, right in
            shortcut.side == "left" ? flags & left != 0 && flags & right == 0 : flags & right != 0 && flags & left == 0
        }
    }
    static func side(flags: UInt64) -> String {
        let active = sides.filter { flags & $0.0 != 0 }
        guard !active.isEmpty else { return "either" }
        if active.allSatisfy({ flags & $0.1 != 0 && flags & $0.2 == 0 }) { return "left" }
        if active.allSatisfy({ flags & $0.2 != 0 && flags & $0.1 == 0 }) { return "right" }
        return "either"
    }
}

struct ShortcutKeyState {
    enum Decision { case pass, consume, fire }
    private var held = Set<UInt16>()
    mutating func reset() { held.removeAll() }
    mutating func process(key: UInt16, keyUp: Bool, capturing: Bool, matches: Bool, repeated: Bool) -> Decision {
        if keyUp { return held.remove(key) != nil ? .consume : .pass }
        if capturing { return .pass }
        if held.contains(key) { return .consume }
        guard matches else { return .pass }
        held.insert(key)
        return repeated ? .consume : .fire
    }
}

@MainActor final class GlobalHotkeys {
    static var capturing = false
    var onRead: (() -> Void)?
    var onDictate: (() -> Void)?
    var onFinish: (() -> Void)?
    var dictating = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var read: Shortcut?
    private var dictate: Shortcut?
    private var keyState = ShortcutKeyState()
    init() {}
    var isActive: Bool { guard let tap else { return false }; return CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap) }
    func apply(read: Shortcut, dictate: Shortcut) throws {
        if tap != nil && !isActive { stop() }
        let nextRead = try read.validated(), nextDictate = try dictate.validated()
        guard !nextRead.conflicts(with: nextDictate) else { throw MacSystemError(message: "Read and Dictate shortcuts overlap. Choose different shortcuts.") }
        guard AXIsProcessTrusted() else { throw MacSystemError(message: "Enable Accessibility for DAVE to use global shortcuts.") }
        if tap == nil {
            let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    Unmanaged<GlobalHotkeys>.fromOpaque(context).takeUnretainedValue().handle(type, event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                throw MacSystemError(message: "macOS could not create the global keyboard event tap. Check Accessibility access and restart DAVE.")
            }
            guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
                CFMachPortInvalidate(newTap)
                throw MacSystemError(message: "macOS could not attach the global keyboard event source.")
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
            tap = newTap; source = newSource
            CGEvent.tapEnable(tap: newTap, enable: true)
        }
        self.read = nextRead; self.dictate = nextDictate
    }
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            keyState.reset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        let isFinish = DictationDeliveryPolicy.isFinishKey(key, modifiers: flags, recording: dictating, capturingShortcut: Self.capturing)
        let isRead = read.map { ShortcutMatcher.matches($0, keyCode: key, flags: flags) } ?? false
        let isDictate = dictate.map { ShortcutMatcher.matches($0, keyCode: key, flags: flags) } ?? false
        switch keyState.process(key: key, keyUp: type == .keyUp, capturing: Self.capturing,
                                matches: isFinish || isRead || isDictate, repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) {
        case .pass: return Unmanaged.passUnretained(event)
        case .consume: return nil
        case .fire:
            let action = isFinish ? onFinish : isRead ? onRead : onDictate
            DispatchQueue.main.async { action?() }
            return nil
        }
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; keyState.reset()
    }
    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    var shortcut: Shortcut
    var onChange: (Shortcut) -> Void
    var onError: (String) -> Void
    func makeNSView(context: Context) -> RecorderButton { let button = RecorderButton(); updateNSView(button, context: context); return button }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.shortcut = shortcut; button.onChange = onChange; button.onError = onError
        if !button.recording { button.title = shortcut.display }
        button.refreshAccessibility()
    }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.finish() }
}

@MainActor final class RecorderButton: NSButton {
    var shortcut = Shortcut(keyCode: 12, modifiers: UInt64(NSEvent.ModifierFlags.option.rawValue))
    var onChange: ((Shortcut) -> Void)?
    var onError: ((String) -> Void)?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    override var acceptsFirstResponder: Bool { true }
    private(set) var recording = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded; target = self; action = #selector(begin)
        refreshAccessibility()
        setAccessibilityHelp("Press to record. Hold modifiers and press a letter or digit. Escape cancels.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func refreshAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Record keyboard shortcut")
        setAccessibilityValue(recording ? "Recording. Press a shortcut or Escape to cancel." : shortcut.display)
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        begin()
        return recording
    }
    @objc private func begin() {
        guard !recording, !GlobalHotkeys.capturing else { return }
        recording = true; GlobalHotkeys.capturing = true
        title = "Press shortcut… Esc cancels"
        refreshAccessibility()
        window?.makeFirstResponder(self)
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.recording else { return false }
                if event.keyCode == 53 { self.finish(); return true }
                let candidate = Shortcut(keyCode: event.keyCode, modifiers: UInt64(event.modifierFlags.rawValue & ShortcutMatcher.genericMask), side: ShortcutMatcher.side(flags: UInt64(event.modifierFlags.rawValue)))
                do { let valid = try candidate.validated(); self.finish(); self.onChange?(valid) }
                catch { self.onError?(error.localizedDescription) }
                return true
            }
            return consumed ? nil : event
        }
    }
    func finish() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if recording { GlobalHotkeys.capturing = false }
        recording = false; title = shortcut.display
        refreshAccessibility()
    }
    override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { finish() }; super.viewWillMove(toWindow: newWindow) }
}

struct AccessibilityProbe: Codable {
    let trusted: Bool
    let canPostEvents: Bool
    let focusedApplicationError: Int32
    static func current() -> AccessibilityProbe {
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &value)
        return AccessibilityProbe(trusted: trusted, canPostEvents: CGPreflightPostEventAccess(), focusedApplicationError: error.rawValue)
    }
    func explanation(fresh: AccessibilityProbe?, shortcutsActive: Bool) -> String {
        if !trusted {
            if fresh?.trusted == true { return "macOS grants access to a fresh process, but this running copy has not picked it up. Save your work, quit DAVE, and reopen this exact app." }
            return "macOS still denies this running copy. In Accessibility Settings, check the app at the path below. An older or rebuilt copy can have a separate grant. Remove the stale entry, add this app, then verify again."
        }
        if focusedApplicationError == AXError.apiDisabled.rawValue { return "macOS reports permission granted, but the Accessibility API is disabled. Save your work and reopen this app, then verify again." }
        if !canPostEvents { return "Accessibility is granted, but macOS still denies keyboard-event posting. Save your work and reopen this app before testing copy and paste in other apps." }
        if !shortcutsActive { return "Accessibility is granted, but global shortcuts could not register. Verify again after closing any app that intercepts these shortcuts." }
        if focusedApplicationError != AXError.success.rawValue { return "Accessibility and global shortcuts verified. The foreground app did not expose an accessible target; try a text field in another app." }
        return "Accessibility and global shortcuts verified for this running app. Individual apps may still restrict text selection or insertion."
    }
    static func freshProcess(executable: URL) async -> AccessibilityProbe? {
        await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = executable; process.arguments = ["--accessibility-probe"]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let deadline = Date().addingTimeInterval(4)
            while process.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
            if process.isRunning { process.terminate(); try? await Task.sleep(nanoseconds: 200_000_000); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; return nil }
            guard process.terminationStatus == 0 else { return nil }
            return try? JSONDecoder().decode(AccessibilityProbe.self, from: output.fileHandleForReading.readDataToEndOfFile())
        }.value
    }
}
