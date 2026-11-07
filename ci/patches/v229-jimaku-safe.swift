
// MARK: - Satori v2.29: Jimaku — the Japanese styles of a bilingual ASS file

/// A bilingual ASS file keeps only its explicitly Japanese styles (jp, jpn, japanese, 日本語): the language of a line
/// is never guessed from its kanji. A file without such a style, or with nothing else in it, stays as it is.
enum JimakuAss {
    /// Rewrites the file at `url` in place. Anything that is not readable UTF-8 is left alone.
    static func keepJapaneseStyles(at url: URL) {
        guard var text = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        let bom = text.unicodeScalars.first == "\u{FEFF}"
        if bom {
            text.unicodeScalars.removeFirst()
        }
        guard let kept = filtered(text.components(separatedBy: "\n")) else {
            return
        }
        let result = (bom ? "\u{FEFF}" : "") + kept.joined(separator: "\n")
        try? result.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The lines without the dialogues of the other styles; nil when there is nothing to remove.
    static func filtered(_ lines: [String]) -> [String]? {
        var inEvents = false
        var fields: [String] = []
        var events: [(index: Int, style: String)] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") {
                inEvents = trimmed.lowercased() == "[events]"
            }
            guard inEvents else {
                continue
            }
            let lower = line.lowercased()
            if lower.hasPrefix("format:") {
                fields = line.dropFirst("format:".count)
                    .split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            } else if lower.hasPrefix("dialogue:"), let at = fields.firstIndex(of: "style") {
                // the text is the last field and may hold commas of its own
                let values = line.dropFirst("dialogue:".count)
                    .split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false)
                guard values.count == fields.count else {
                    continue
                }
                events.append((index: index, style: values[at].trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        let japanese = Set(events.map { $0.style }.filter { isJapanese($0) })
        guard !japanese.isEmpty else {
            return nil
        }
        let remove = Set(events.filter { !japanese.contains($0.style) }.map { $0.index })
        guard !remove.isEmpty else {
            return nil
        }
        return lines.enumerated().filter { !remove.contains($0.offset) }.map { $0.element }
    }

    /// "JP", "Default-jpn", "Japanese Main", "日本語": the word stands between non-letters.
    static func isJapanese(_ style: String) -> Bool {
        style.range(of: #"(?:^|[^a-zA-Z])(?:jp|jpn|japanese)(?:$|[^a-zA-Z])|日本語"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }
}
