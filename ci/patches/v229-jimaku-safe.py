# v2.29: Jimaku — the safe download and the best file, as in anicli-ru-jimaku.
# - A subtitle file is taken only from https://jimaku.cc, and the API key goes only there: before, the key was sent to
#   whatever address the API returned. A file larger than 32 MiB is refused (the size from the list, and again for
#   what came down).
# - The best file comes first: ASS (it keeps the typesetting) before SRT and the rest, then the release of the video
#   (BD / WEB), then Japanese before other languages; files of the same rank in the order of their names, so the
#   choice does not change from one search to the next.
# - A bilingual ASS file keeps only its explicitly Japanese styles (jp, jpn, japanese, 日本語): the language of a line
#   is never guessed from its kanji. A file with no such style stays as it is.
import pathlib


def once(text, old, new, label):
    assert text.count(old) == 1, "pattern not found exactly once: " + label
    return text.replace(old, new)


here = pathlib.Path(__file__).resolve().parent
hv = pathlib.Path("src/safari/iOS (App)/HelpView.swift")
s = hv.read_text(encoding="utf-8")

# ---------- a file that is too large is a failure of its own ----------
s = once(s, '''    enum Failure: Error {
        case status(Int)
        case badURL
    }
''', '''    enum Failure: Error {
        case status(Int)
        case badURL
        case tooLarge
    }
''', "failure cases")

# ---------- the download: jimaku.cc over https only, at most 32 MiB ----------
s = once(s, '''    static func download(_ file: FileEntry, key: String) async throws -> URL {
        guard let url = URL(string: file.url) else { throw Failure.badURL }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(key, forHTTPHeaderField: "Authorization")
        let (temp, response) = try await URLSession.shared.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.status(status) }
        return temp
    }
''', '''    /// No subtitle file is larger than this.
    static let maxBytes = 32 * 1024 * 1024

    /// The file comes from jimaku.cc over https (the API key goes along with the request, so no other host gets it)
    /// and is not too large.
    static func isTrusted(_ file: FileEntry) -> Bool {
        guard let url = URL(string: file.url), url.scheme == "https", url.host?.lowercased() == "jimaku.cc" else {
            return false
        }
        return file.size <= maxBytes
    }

    static func download(_ file: FileEntry, key: String) async throws -> URL {
        guard let url = URL(string: file.url), isTrusted(file) else { throw Failure.badURL }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(key, forHTTPHeaderField: "Authorization")
        let (temp, response) = try await URLSession.shared.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.status(status) }
        let attributes = try? FileManager.default.attributesOfItem(atPath: temp.path)
        guard ((attributes?[.size] as? Int) ?? 0) <= maxBytes else {
            try? FileManager.default.removeItem(at: temp)
            throw Failure.tooLarge
        }
        let ext = (file.name as NSString).pathExtension.lowercased()
        if ext == "ass" || ext == "ssa" {
            JimakuAss.keepJapaneseStyles(at: temp)
        }
        return temp
    }
''', "download")

# ---------- the choice: ASS first, then the release, then Japanese ----------
s = once(s, '''    /// subtitle files only, Japanese first, the release of the video first, at most five
    static func pickFiles(_ files: [FileEntry], release: String?) -> [FileEntry] {
        let subs = files.filter { ["srt", "ass", "ssa", "vtt"].contains(($0.name as NSString).pathExtension.lowercased()) }
        func score(_ f: FileEntry) -> Int {
            var s = 0
            if let release, f.name.uppercased().contains(release) { s += 2 }
            if f.name.range(of: #"\\b(ENG|CHS|CHT|CHI)\\b"#, options: [.regularExpression, .caseInsensitive]) != nil { s -= 5 }
            return s
        }
        return Array(subs.sorted { score($0) > score($1) }.prefix(5))
    }
''', '''    /// subtitle files only, from jimaku.cc and not too large; ASS first (it keeps the typesetting), then the release of
    /// the video, then Japanese before other languages; the same rank in the order of the names; at most five
    static func pickFiles(_ files: [FileEntry], release: String?) -> [FileEntry] {
        let subs = files.filter {
            ["srt", "ass", "ssa", "vtt"].contains(($0.name as NSString).pathExtension.lowercased()) && isTrusted($0)
        }
        func score(_ f: FileEntry) -> Int {
            var s = 0
            let ext = (f.name as NSString).pathExtension.lowercased()
            if ext == "ass" || ext == "ssa" { s += 3 }
            if let release, f.name.uppercased().contains(release) { s += 2 }
            if f.name.range(of: #"\\b(ENG|CHS|CHT|CHI)\\b"#, options: [.regularExpression, .caseInsensitive]) != nil { s -= 5 }
            return s
        }
        let ranked = subs.sorted { a, b in
            let x = score(a), y = score(b)
            return x != y ? x > y : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return Array(ranked.prefix(5))
    }
''', "pick files")

# ---------- the Japanese styles of a bilingual ASS file ----------
s = s.rstrip("\n") + "\n" + (here / "v229-jimaku-safe.swift").read_text(encoding="utf-8")

hv.write_text(s, encoding="utf-8")
print("v2.29 Jimaku applied")
