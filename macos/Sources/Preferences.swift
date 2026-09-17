import Foundation
import AppKit
import Combine

struct PreferenceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64
    var side: String
    init(keyCode: UInt16, modifiers: UInt64, side: String = "either") {
        self.keyCode = keyCode; self.modifiers = modifiers; self.side = side
    }
    static let keys: [UInt16: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",25:"9",26:"7",28:"8",29:"0",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M"]
    static let allowedModifiers = UInt64(NSEvent.ModifierFlags([.command, .option, .control, .shift]).rawValue)
    var display: String {
        let flags: [(NSEvent.ModifierFlags, String)] = [(.control,"⌃"),(.option,"⌥"),(.shift,"⇧"),(.command,"⌘")]
        return (side == "either" ? "" : side.capitalized + " ") + flags.filter { modifiers & UInt64($0.0.rawValue) != 0 }.map { $0.1 }.joined() + (Self.keys[keyCode] ?? "Key \(keyCode)")
    }
    func conflicts(with other: Shortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers && (side == other.side || side == "either" || other.side == "either")
    }
    func validated() throws -> Shortcut {
        guard Self.keys[keyCode] != nil else { throw PreferenceError(message: "Choose a letter or number for the shortcut.") }
        guard modifiers != 0 && modifiers & ~Self.allowedModifiers == 0 else { throw PreferenceError(message: "Use Command, Option, Control, or Shift with the shortcut key.") }
        guard ["either", "left", "right"].contains(side) else { throw PreferenceError(message: "Choose either, left, or right modifier keys.") }
        return self
    }
}

struct VoicePreferences: Codable, Equatable {
    var generateAhead: Int = 5
    var rate: Double = 1
    var ttsModel: String = "system"
    var sttModel: String = "whisper-tiny"
    var dictationDevice = "auto"
    var transcriptionDevice = "auto"
    var speakerModel = "compact"
    var transcriptionModel: String = "whisper-small"
    var readingVoices: [String: String] = [:]
    var voice: String = "af_heart"
    var systemVoice: String = ""
    var readCode: Bool = false
    var overlayTop: Bool = false
    var readShortcut = Shortcut(keyCode: 12, modifiers: UInt64(NSEvent.ModifierFlags.option.rawValue))
    var dictateShortcut = Shortcut(keyCode: 13, modifiers: UInt64(NSEvent.ModifierFlags.option.rawValue))
    init() {}
    enum CodingKeys: String, CodingKey { case speakerModel, dictationDevice, transcriptionDevice, transcriptionModel, readingVoices, systemVoice, generateAhead, rate, ttsModel, sttModel, voice, readCode, overlayTop, readShortcut, dictateShortcut }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generateAhead = try c.decodeIfPresent(Int.self, forKey: .generateAhead) ?? 5
        rate = try c.decodeIfPresent(Double.self, forKey: .rate) ?? rate
        ttsModel = try c.decodeIfPresent(String.self, forKey: .ttsModel) ?? ttsModel
        sttModel = try c.decodeIfPresent(String.self, forKey: .sttModel) ?? sttModel
        systemVoice = try c.decodeIfPresent(String.self, forKey: .systemVoice) ?? ""
        transcriptionModel = try c.decodeIfPresent(String.self, forKey: .transcriptionModel) ?? sttModel
        speakerModel = try c.decodeIfPresent(String.self, forKey: .speakerModel) ?? "compact"
        dictationDevice = try c.decodeIfPresent(String.self, forKey: .dictationDevice) ?? "auto"
        transcriptionDevice = try c.decodeIfPresent(String.self, forKey: .transcriptionDevice) ?? "auto"
        readingVoices = try c.decodeIfPresent([String: String].self, forKey: .readingVoices) ?? [:]
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? voice
        readCode = try c.decodeIfPresent(Bool.self, forKey: .readCode) ?? readCode
        overlayTop = try c.decodeIfPresent(Bool.self, forKey: .overlayTop) ?? overlayTop
        readShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .readShortcut) ?? readShortcut
        dictateShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .dictateShortcut) ?? dictateShortcut
    }
    func validated() throws -> VoicePreferences {
        guard ["auto", "cpu", "metal"].contains(dictationDevice), ["auto", "cpu", "metal"].contains(transcriptionDevice) else { throw PreferenceError(message: "Choose Automatic, CPU, or Apple GPU for recognition.") }
        guard ["compact", "accurate", "precision"].contains(speakerModel) else { throw PreferenceError(message: "Choose a supported speaker identification model.") }
        guard (3...10).contains(generateAhead) else { throw PreferenceError(message: "Generate ahead must be between 3 and 10 sentences.") }
        guard rate.isFinite && (0.5...2).contains(rate) else { throw PreferenceError(message: "Reading speed must be between 0.5× and 2×.") }
        _ = try readShortcut.validated(); _ = try dictateShortcut.validated()
        guard !readShortcut.conflicts(with: dictateShortcut) else { throw PreferenceError(message: "Read and dictate shortcuts must be different.") }
        return self
    }
}

@MainActor final class PreferencesStore: ObservableObject {
    @Published private(set) var value: VoicePreferences
    @Published private(set) var error: String?
    private let url: URL
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LocalVoiceNative/preferences.json")
        self.value = VoicePreferences()
        if FileManager.default.fileExists(atPath: self.url.path) {
            do { self.value = try JSONDecoder().decode(VoicePreferences.self, from: Data(contentsOf: self.url)).validated() }
            catch { self.error = "Could not load saved preferences: \(error.localizedDescription)" }
        }
    }
    func update(_ transform: (inout VoicePreferences) -> Void) throws {
        var candidate = value
        transform(&candidate)
        do {
            candidate = try candidate.validated()
            let data = try JSONEncoder().encode(candidate)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            value = candidate; error = nil
        } catch {
            self.error = "Could not save preferences: \(error.localizedDescription)"
            throw error
        }
    }
}
