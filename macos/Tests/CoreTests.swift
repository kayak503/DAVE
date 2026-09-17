import Foundation
import AppKit

@main struct CoreTests {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { fatalError("FAIL: \(message)") }
        }
        func rejects(_ message: String, _ operation: () throws -> Void) {
            checks += 1
            do { try operation(); fatalError("FAIL: \(message)") } catch {}
        }
        let oldJSON = Data(#"{"rate":1.2,"ttsModel":"kokoro-q8","voice":"af_heart"}"#.utf8)
        let migrated = try JSONDecoder().decode(VoicePreferences.self, from: oldJSON).validated()
        expect(migrated.generateAhead == 5 && migrated.rate == 1.2 && migrated.ttsModel == "kokoro-q8", "migration retains existing choices")
        for depth in [3, 5, 10] {
            var prefs = migrated; prefs.generateAhead = depth
            let saved = try JSONDecoder().decode(VoicePreferences.self, from: JSONEncoder().encode(prefs))
            let validated = try saved.validated()
            expect(validated == prefs, "generation depth roundtrip")
        }
        for depth in [0, 2, 11] {
            rejects("invalid generation depth") { var prefs = migrated; prefs.generateAhead = depth; _ = try prefs.validated() }
        }
        var voicePrefs = migrated
        voicePrefs.voice = "bm_george"; voicePrefs.systemVoice = "com.apple.voice.example"
        let voiceRoundtrip = try JSONDecoder().decode(VoicePreferences.self, from: JSONEncoder().encode(voicePrefs))
        expect(voiceRoundtrip.voice == "bm_george" && voiceRoundtrip.systemVoice == "com.apple.voice.example", "independent Mac and Kokoro voice choices persist")
        expect(migrated.systemVoice.isEmpty, "old preferences default to Mac default voice")
        expect(migrated.transcriptionModel == migrated.sttModel, "migration preserves existing audio-file model")
        expect(VoicePreferences().transcriptionModel == "whisper-small", "new installation recommends Small for files")
        var independent = migrated
        independent.transcriptionModel = "whisper-large-turbo"
        independent.readingVoices = ["kokoro-q8": "am_michael", "supertonic-3": "M1"]
        let independentRoundtrip = try JSONDecoder().decode(VoicePreferences.self, from: JSONEncoder().encode(independent))
        expect(independentRoundtrip.sttModel == "whisper-tiny" && independentRoundtrip.transcriptionModel == "whisper-large-turbo", "transcription selection never changes dictation")
        expect(independentRoundtrip.readingVoices == independent.readingVoices, "voices retained independently by reading model")
        let document = """
        # **Welcome**

        Dr. Smith reads [a link](https://example.com). The rate is 1.5 today!
        This is *pleasant*, with `inline code` and snake_case.

        - [x] First item.
        2. Second item?

        ```swift
        let secret = 42
        ```
        After code.
        """
        let parsed = DocumentParser.sentences(document)
        expect(parsed.map(\.text) == ["Welcome", "Dr. Smith reads a link.", "The rate is 1.5 today!", "This is pleasant, with inline code and snake_case.", "First item.", "Second item?", "After code."], "Markdown and sentence preparation: \(parsed)")
        expect(parsed.map(\.kind) == ["heading","paragraph","paragraph","paragraph","list","list","paragraph"], "Metadata")
        expect(parsed.map(\.id) == Array(0..<parsed.count), "Stable sequential identifiers")
        let withCode = DocumentParser.sentences(document, readCode: true)
        expect(withCode.contains { $0.text == "let secret = 42" && $0.kind == "code" }, "Code explicitly read")
        expect(DocumentParser.sentences("~~~python\nprint(1)\n~~~\nDone.").map(\.text) == ["Done."], "Tilde fence skipped")
        expect(DocumentParser.sentences("```\nunclosed", readCode: true).first?.text == "unclosed", "Unclosed fence")
        expect(DocumentParser.sentences("Title\n=====\n\n> Hello &amp; goodbye.").map(\.text) == ["Title", "Hello & goodbye."], "Setext and quote")
        expect(DocumentParser.sentences("A. Jones likes the U.S. team. Yes! \"Good?\" Next.").map(\.text) == ["A. Jones likes the U.S. team.", "Yes!", "\"Good?\"", "Next."], "Initials, abbreviations and quotation boundaries")
        expect(DocumentParser.sentences("  \n\n").isEmpty, "Empty input")
        expect(DocumentParser.sentences("[Read][ref].\n\n[ref]: https://example.com").map(\.text) == ["Read."], "Reference definitions are not spoken")
        expect(DocumentParser.sentences("One... Two?! Three.").map(\.text) == ["One...", "Two?!", "Three."], "Consecutive punctuation")
        let formatted = DocumentParser.sentences("**Bold first. Bold second.** Then [a link](https://example.com) and *emphasis*.")
        expect(formatted.count == 3, "Formatted multi-sentence boundaries")
        for sentence in formatted {
            let rendered = try AttributedString(markdown: sentence.display, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            expect(String(rendered.characters) == sentence.text, "Display and spoken fragment aligned")
        }
        for sentence in formatted.prefix(2) {
            let rendered = try AttributedString(markdown: sentence.display)
            expect(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "Bold preserved across sentence boundary")
        }
        let linked = try AttributedString(markdown: formatted[2].display)
        expect(linked.runs.contains { $0.link?.absoluteString == "https://example.com" }, "Link retained in display")
        expect(linked.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true }, "Emphasis retained in display")
        let codeInline = DocumentParser.sentences("Use `a_b` now.")[0]
        let renderedCode = try AttributedString(markdown: codeInline.display)
        expect(String(renderedCode.characters) == codeInline.text && renderedCode.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true }, "Inline code retained in display")
        expect(DocumentParser.sentences("<https://example.com>").first?.text == "https://example.com", "Autolink retained")
        let longPlain = String(repeating: "a", count: 2501)
        let longEmoji = String(repeating: "👨‍👩‍👧‍👦", count: 230)
        for (source, original, kind) in [(longPlain, longPlain, "paragraph"), (longEmoji, longEmoji, "paragraph"), ("# " + longPlain, longPlain, "heading"), ("```\n" + longEmoji + "\n```", longEmoji, "code"), ("**" + longPlain + "**", longPlain, "paragraph")] {
            let fragments = DocumentParser.sentences(source, readCode: true)
            expect(fragments.count >= 3, "Long input chunked")
            expect(fragments.allSatisfy { !$0.text.isEmpty && $0.text.utf16.count <= 1000 && $0.kind == kind }, "Every chunk bounded in UTF16 units with metadata")
            expect(fragments.map(\.text).joined() == original, "Chunking preserves all graphemes")
            expect(fragments.map(\.id) == Array(0..<fragments.count), "Chunk identifiers contiguous")
            if kind != "code" {
                for fragment in fragments {
                    let rendered = try AttributedString(markdown: fragment.display, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
                    expect(String(rendered.characters) == fragment.text, "Long display aligned")
                }
            }
        }
        let hugeGrapheme = "a" + String(repeating: "\u{0301}", count: 1100)
        expect(DocumentParser.sentences(hugeGrapheme).allSatisfy { $0.text.utf16.count <= 1000 }, "Pathological single grapheme is explained rather than split")
        let option = UInt64(NSEvent.ModifierFlags.option.rawValue)
        let command = UInt64(NSEvent.ModifierFlags.command.rawValue)
        let generic = Shortcut(keyCode: 12, modifiers: option)
        let left = Shortcut(keyCode: 12, modifiers: option, side: "left")
        let right = Shortcut(keyCode: 12, modifiers: option, side: "right")
        expect(generic.conflicts(with: left) && left.conflicts(with: generic), "Generic conflicts symmetric")
        expect(!left.conflicts(with: right), "Distinct sides")
        expect(!left.conflicts(with: Shortcut(keyCode: 12, modifiers: command, side: "left")), "Distinct modifiers")
        let combined = try Shortcut(keyCode: 18, modifiers: option | command, side: "right").validated()
        expect(combined.display == "Right ⌥⌘1", "Combined display")
        let decoded = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(combined))
        expect(decoded == combined, "Shortcut Codable")
        rejects("No bare key") { _ = try Shortcut(keyCode: 12, modifiers: 0).validated() }
        rejects("No function key") { _ = try Shortcut(keyCode: 122, modifiers: option).validated() }
        rejects("No invalid flags") { _ = try Shortcut(keyCode: 12, modifiers: UInt64.max).validated() }
        rejects("No invalid side") { _ = try Shortcut(keyCode: 12, modifiers: option, side: "up").validated() }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("localvoice-core-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = temporary.appendingPathComponent("nested/preferences.json")
        let store = PreferencesStore(url: url)
        expect(store.value == VoicePreferences() && store.error == nil, "First run defaults")
        try store.update { $0.rate = 1.7; $0.readCode = true; $0.overlayTop = true; $0.readShortcut = combined; $0.voice = "af_bella" }
        expect(PreferencesStore(url: url).value == store.value, "Automatic persisted full preferences")
        let durable = store.value
        let durableBytes = try Data(contentsOf: url)
        for rate in [0.49, 2.01, Double.nan, Double.infinity] {
            rejects("Invalid rate") { try store.update { $0.rate = rate } }
            expect(store.value == durable, "Invalid rate rollback")
        }
        rejects("Conflict rollback") { try store.update { $0.dictateShortcut = $0.readShortcut } }
        expect(store.value == durable, "Conflict keeps last durable state")
        let afterInvalid = try Data(contentsOf: url)
        expect(afterInvalid == durableBytes, "Invalid updates preserve disk")
        try store.update { $0.rate = 0.5 }
        try store.update { $0.rate = 2 }
        expect(store.error == nil && PreferencesStore(url: url).value.rate == 2, "Boundary rates and cleared error")
        // A file where the parent directory belongs forces a genuine filesystem failure,
        // independent of the effective user's permission privileges.
        let blockedParent = temporary.appendingPathComponent("blocker")
        try Data("block".utf8).write(to: blockedParent)
        let blocked = PreferencesStore(url: blockedParent.appendingPathComponent("preferences.json"))
        rejects("Filesystem failure") { try blocked.update { $0.rate = 1.8 } }
        expect(blocked.value == VoicePreferences() && blocked.error != nil, "Write failure preserves durable state")
        let savedStore = PreferencesStore(url: url)
        let savedValue = savedStore.value
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        rejects("Existing durable write failure") { try savedStore.update { $0.voice = "changed" } }
        expect(savedStore.value == savedValue && savedStore.error != nil, "Filesystem failure retains loaded durable preferences")
        try FileManager.default.removeItem(at: url)
        try Data("broken JSON".utf8).write(to: url)
        let corrupt = PreferencesStore(url: url)
        expect(corrupt.value == VoicePreferences() && corrupt.error != nil, "Corrupt preferences visible recovery")
        try corrupt.update { $0.rate = 1.2 }
        expect(PreferencesStore(url: url).value.rate == 1.2, "Recover corrupt preferences through explicit update")
        expect(migrated.dictationDevice == "auto" && migrated.transcriptionDevice == "auto", "existing preferences default to automatic acceleration")
        try store.update { $0.dictationDevice = "cpu"; $0.transcriptionDevice = "metal" }
        let devices = PreferencesStore(url: url).value
        expect(devices.dictationDevice == "cpu" && devices.transcriptionDevice == "metal", "independent processors persist")
        var invalidDevice = VoicePreferences(); invalidDevice.transcriptionDevice = "cuda"
        do { _ = try invalidDevice.validated(); expect(false, "invalid processor rejected") } catch { expect(true, "invalid processor rejected") }
        expect(migrated.speakerModel == "compact", "existing installs retain compact speaker model")
        try store.update { $0.speakerModel = "precision" }
        expect(PreferencesStore(url: url).value.speakerModel == "precision", "precision speaker model persists")
        try store.update { $0.speakerModel = "accurate" }
        expect(PreferencesStore(url: url).value.speakerModel == "accurate", "larger speaker model selection persists")
        print("NATIVE_UNIT_OK \(checks) assertions")
    }
}
