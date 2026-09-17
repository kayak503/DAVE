import Foundation

struct SpokenSentence: Identifiable, Equatable {
    let id: Int
    let text: String
    let display: String
    let kind: String
}

enum DocumentParser {
    static func sentences(_ source: String, readCode: Bool = false) -> [SpokenSentence] {
        var result: [SpokenSentence] = []
        var paragraph: [String] = []
        var fence: Character?
        var fenceLength = 0
        var code: [String] = []
        func append(_ text: String, kind: String, split: Bool = true) {
            // A single pathological combining sequence can exceed the engine limit.
            // Keep it intact by substituting a spoken explanation, never slicing it.
            let boundedInput = text.map { String($0).utf16.count > 1000 ? "[unreadable character]" : String($0) }.joined()
            let attributed = kind == "code" ? AttributedString(boundedInput) : inlineMarkdown(boundedInput)
            let plain = String(attributed.characters)
            var cursor = plain.startIndex
            for sentence in split ? splitSentences(plain) : [plain] {
                for fragment in chunks(sentence) {
                    guard let range = plain.range(of: fragment, range: cursor..<plain.endIndex) else { continue }
                    cursor = range.upperBound
                    let lower = attributed.characters.index(attributed.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.lowerBound))
                    let upper = attributed.characters.index(lower, offsetBy: fragment.count)
                    let display = kind == "code" ? fragment : markdownDisplay(AttributedString(attributed[lower..<upper]))
                    result.append(SpokenSentence(id: result.count, text: fragment, display: display, kind: kind))
                }
            }
        }
        func flush() {
            if !paragraph.isEmpty { append(paragraph.joined(separator: " "), kind: "paragraph"); paragraph.removeAll() }
        }
        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            let marker = line.first
            let run = line.prefix(while: { $0 == marker }).count
            if let active = fence {
                if marker == active && run >= fenceLength && line.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty {
                    if readCode { append(code.joined(separator: "\n"), kind: "code", split: false) }
                    code.removeAll(); fence = nil
                } else { code.append(String(raw)) }
                continue
            }
            if (marker == "`" || marker == "~") && run >= 3 {
                flush(); fence = marker; fenceLength = run; continue
            }
            if line.isEmpty { flush(); continue }
            if line.range(of: #"^\[[^\]]+\]:\s*\S+"#, options: .regularExpression) != nil { flush(); continue }
            if line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil {
                flush(); append(line.replacingOccurrences(of: #"^#{1,6}\s+|\s+#+\s*$"#, with: "", options: .regularExpression), kind: "heading", split: false)
            } else if line.range(of: #"^([-*+]\s+|\d+[.)]\s+)"#, options: .regularExpression) != nil {
                flush(); append(line.replacingOccurrences(of: #"^([-*+]\s+|\d+[.)]\s+)(\[[ xX]\]\s+)?"#, with: "", options: .regularExpression), kind: "list")
            } else if line.range(of: #"^(=+|-+)\s*$"#, options: .regularExpression) != nil && !paragraph.isEmpty {
                append(paragraph.joined(separator: " "), kind: "heading", split: false); paragraph.removeAll()
            } else if line.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) == nil {
                paragraph.append(line.replacingOccurrences(of: #"^>\s?"#, with: "", options: .regularExpression))
            } else { flush() }
        }
        flush()
        if fence != nil && readCode { append(code.joined(separator: "\n"), kind: "code", split: false) }
        return result
    }

    private static func inlineMarkdown(_ input: String) -> AttributedString {
        var text = input
        // Reference definitions are removed at block level; keep their readable labels.
        for (pattern, replacement) in [
            (#"!?\[([^\]]+)\]\[[^\]]*\]"#, "$1"),
            (#"!\[([^\]]*)\]\([^\n)]*\)"#, "$1"),
            (#"</?[A-Za-z][A-Za-z0-9-]*(?:\s[^>]*)?/?>"#, "")
        ] { text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression) }
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private static func markdownDisplay(_ attributed: AttributedString) -> String {
        attributed.runs.map { run in
            let raw = String(attributed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var rendered: String
            if intent.contains(.code) {
                let longest = raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
                let delimiter = String(repeating: "`", count: longest + 1)
                rendered = delimiter + " " + raw + " " + delimiter
            } else {
                rendered = raw.map { "\\`*_[]<>".contains($0) ? "\\" + String($0) : String($0) }.joined()
                if intent.contains(.stronglyEmphasized) { rendered = "**" + rendered + "**" }
                if intent.contains(.emphasized) { rendered = "*" + rendered + "*" }
                if intent.contains(.strikethrough) { rendered = "~~" + rendered + "~~" }
            }
            if let link = run.link { rendered = "[" + rendered + "](" + link.absoluteString.replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: "(", with: "%28") + ")" }
            return rendered
        }.joined()
    }

    private static func chunks(_ text: String) -> [String] {
        var result: [String] = []
        var buffer = ""
        var units = 0
        for character in text {
            let width = String(character).utf16.count
            if units + width > 1000 {
                let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                buffer = ""; units = 0
            }
            buffer.append(character); units += width
        }
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }

    private static func splitSentences(_ text: String) -> [String] {
        let chars = Array(text)
        let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e", "fig", "no"]
        var start = 0
        var output: [String] = []
        for i in chars.indices where ".!?".contains(chars[i]) {
            if i + 1 < chars.count && ".!?".contains(chars[i + 1]) { continue }
            if chars[i] == "." {
                var tokenStart = i
                while tokenStart > start && !chars[tokenStart - 1].isWhitespace { tokenStart -= 1 }
                let word = String(chars[tokenStart..<i]).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\"'“‘([{"))
                if abbreviations.contains(word) || (word.count == 1 && word.first?.isLetter == true) || word.range(of: #"^(?:[a-z]\.)+[a-z]$"#, options: .regularExpression) != nil { continue }
            }
            var end = i + 1
            while end < chars.count && "\"'”’)]}".contains(chars[end]) { end += 1 }
            guard end == chars.count || chars[end].isWhitespace else { continue }
            let part = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { output.append(part) }
            start = end
        }
        let rest = String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { output.append(rest) }
        return output
    }
}
