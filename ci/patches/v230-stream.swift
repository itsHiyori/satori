
// MARK: - Satori v2.30: watching online (a torrent streamed while it downloads, Jimaku subtitles)

import Network

extension SatoriTorrent: @unchecked Sendable {}

enum Rx {
    static func first(_ pattern: String, _ text: String, caseInsensitive: Bool = true) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else {
            return nil
        }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    static func all(_ pattern: String, _ text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    static func test(_ pattern: String, _ text: String) -> Bool {
        first(pattern, text) != nil
    }
}

/// The choice of the release and of the file, as in anicli-ru-jimaku: a batch that holds the episode, then one file of it.
@available(iOS 16.0, *)
enum TorrentSearch {
    struct Release {
        let name: String
        let magnet: String
        let seeders: Int
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let trackers = [
        "http://nyaa.tracker.wf:7777/announce",
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://exodus.desync.com:6969/announce",
    ]

    private static let seasonTail = #"\s*(?:\d+(?:st|nd|rd|th)\s+season|season\s*\d+|s\d{1,2})\s*$"#

    /// Letters and digits only: «[Oshi no Ko]», «Frieren: Beyond…» and «Frieren - Beyond…» compare as equal.
    static func norm(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The names a release can carry: both names of the Jimaku entry, with and without «Season N», without brackets.
    static func searchTitles(_ entry: JimakuService.Entry) -> [String] {
        var titles: [String] = []
        for title in [entry.name, entry.english_name].compactMap({ $0 }) {
            let plain = title.replacingOccurrences(of: #"[\[\]【】]"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let bare = plain.replacingOccurrences(of: seasonTail, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
            for candidate in [plain, bare] where !norm(candidate).isEmpty
                && !titles.contains(where: { norm($0) == norm(candidate) }) {
                titles.append(candidate)
            }
        }
        return titles
    }

    /// What Nyaa is asked: the titles, and for a later season the bare title with «S02» (releases named that way are
    /// not among the most seeded ones of the bare title).
    static func queries(_ titles: [String], season: Int) -> [String] {
        var out = titles
        guard season > 1 else { return out }
        for title in titles {
            let bare = title.replacingOccurrences(of: seasonTail, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
            let query = bare + String(format: " S%02d", season)
            if !out.contains(query) {
                out.append(query)
            }
        }
        return out
    }

    /// One of the names of the release (they are split by « | » and « / », the group in front is cut) starts with the
    /// title; what follows is a number, a season or the quality, not another title.
    static func matches(_ release: String, titles: [String]) -> Bool {
        let parts = release.replacingOccurrences(of: #"^\s*\[[^\]]*\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s[|/]\s"#, with: "\n", options: .regularExpression)
            .components(separatedBy: "\n").map(norm)
        let wanted = titles.map(norm).filter { !$0.isEmpty }
        for clean in parts {
            for title in wanted {
                if clean == title {
                    return true
                }
                if clean.hasPrefix(title + " "), Rx.test(
                    #"^(?:\d|season\b|s\d|batch\b|complete\b|bd|blu|web|tv\b|dual|multi|hevc|x26|h26|av1|remux|vostfr|uncensored)"#,
                    String(clean.dropFirst(title.count + 1))) {
                    return true
                }
            }
        }
        return false
    }

    static func seasonNumber(_ name: String) -> Int? {
        guard let g = Rx.first(#"(?:\bseason[ ._-]*(\d+)|\b(\d+)(?:st|nd|rd|th) season|(?<![a-z0-9])s(\d{1,2})(?:e\d+)?(?![a-z0-9]))"#, name) else {
            return nil
        }
        return g.dropFirst().compactMap { Int($0) }.first
    }

    /// The episode of a release of one episode: « - 06» first («- 06 (S03E30)» counts from the first season), then S03E06.
    static func episodeNumber(_ name: String) -> Int? {
        let g = Rx.first(#"\s-\s(\d{1,3})(?:v\d)?(?=\s|\[|\(|$)"#, name) ?? Rx.first(#"s\d+e(\d+)"#, name)
        return g.flatMap { Int($0[1]) }
    }

    /// The releases of the season that hold the episode, the best to stream first. A release of that episode alone
    /// with 20 seeders or more goes before the batches: its pieces are 1-2 MB and the file is small, while a Blu-ray
    /// batch has 16 MB pieces and a bitrate above the download speed (2.32 took one and never began to play).
    /// Then by seeders.
    static func ranked(_ items: [Release], episode: Int, season: Int) -> [Release] {
        var usable: [(release: Release, single: Bool)] = []
        for item in items where item.seeders > 0 {
            let name = item.name
            // raw TV captures: MPEG-2 transport streams of several GB
            if Rx.test(#"\.ts$|mpeg-?2"#, name) {
                continue
            }
            let found = seasonNumber(name)
            if let found, found != season {
                continue
            }
            if season > 1 && found == nil {
                continue
            }
            if let number = episodeNumber(name) {
                if number == episode {
                    usable.append((item, item.seeders >= 20))
                }
                continue
            }
            let ranges = Rx.all(#"(?<!\d)(\d{1,3})\s*[-~–]\s*(\d{1,3})(?!\d)"#, name)
            if !ranges.isEmpty && !ranges.contains(where: { (Int($0[1]) ?? 0) <= episode && episode <= (Int($0[2]) ?? 0) }) {
                continue
            }
            usable.append((item, false))
        }
        return usable.sorted { ($0.single ? 1 : 0, $0.release.seeders) > ($1.single ? 1 : 0, $1.release.seeders) }
            .map { $0.release }
    }

    /// One video file of the episode: extras, specials, samples, NCOP and NCED are out; two matches stop the choice.
    static func episodeFile(_ files: [SatoriTorrentFile], episode: Int) throws -> SatoriTorrentFile {
        var found: [SatoriTorrentFile] = []
        for file in files {
            let path = file.path as NSString
            guard ["mkv", "mp4", "avi", "webm", "m4v"].contains(path.pathExtension.lowercased()) else { continue }
            if path.pathComponents.contains(where: { Rx.test(#"\b(?:extras?|specials?|samples?|ncop|nced)\b"#, $0) }) {
                continue
            }
            let stem = path.lastPathComponent.replacingOccurrences(of: "." + path.pathExtension, with: "")
            let name = stem.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
            var number: Int?
            if let g = Rx.first(#"(?:s\d{1,2}e|\bep(?:isode)?[ ._-]*)(\d{1,4})(?!\d)"#, name) {
                number = Int(g[1])
            } else if let g = Rx.first(#"(?:^|\s-\s|[ ._])(\d{1,3})(?:v\d)?(?:[ ._]*$)"#,
                                       name.trimmingCharacters(in: .whitespaces)) {
                number = Int(g[1])
            }
            if number == episode {
                found.append(file)
            }
        }
        guard found.count == 1 else {
            throw Failure(message: "Для серии \(episode) найдено файлов: \(found.count). Автовыбор остановлен.")
        }
        return found[0]
    }

    static func search(_ title: String) async throws -> [Release] {
        var components = URLComponents(string: "https://nyaa.si/")!
        components.queryItems = [
            URLQueryItem(name: "page", value: "rss"), URLQueryItem(name: "q", value: title),
            URLQueryItem(name: "c", value: "1_0"), URLQueryItem(name: "f", value: "0"),
            URLQueryItem(name: "s", value: "seeders"), URLQueryItem(name: "o", value: "desc"),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.setValue("Satori", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(message: "Nyaa не отвечает")
        }
        let reader = RSSReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.items.compactMap { item in
            guard let name = item["title"], let hash = item["nyaa:infoHash"], !hash.isEmpty else { return nil }
            let dn = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let tr = trackers.map { "&tr=" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") }.joined()
            return Release(name: name, magnet: "magnet:?xt=urn:btih:\(hash)&dn=\(dn)\(tr)",
                           seeders: Int(item["nyaa:seeders"] ?? "") ?? 0)
        }
    }
}

private final class RSSReader: NSObject, XMLParserDelegate {
    var items: [[String: String]] = []
    private var current: [String: String]?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "item" {
            current = [:]
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item", let current {
            items.append(current)
            self.current = nil
        } else if current != nil {
            current?[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// A local HTTP server (loopback only) that gives the player the selected file of the torrent with byte ranges:
/// what is not downloaded yet is waited for, and the pieces under the player's reading position come first.
final class StreamServer: @unchecked Sendable {
    private let torrent: SatoriTorrent
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "satori.stream.server")
    private(set) var port: UInt16 = 0

    init(torrent: SatoriTorrent) {
        self.torrent = torrent
    }

    func start() async -> Bool {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let listener = try? NWListener(using: parameters, on: .any) else {
            return false
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var finished = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !finished else { return }
                switch state {
                case .ready:
                    finished = true
                    self?.port = listener.port?.rawValue ?? 0
                    continuation.resume(returning: (self?.port ?? 0) != 0)
                case .failed, .cancelled:
                    finished = true
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let torrent = self.torrent
        Task.detached {
            await StreamServer.serve(connection, torrent)
            connection.cancel()
        }
    }

    private static func readRequest(_ c: NWConnection) async -> String? {
        var buffer = Data()
        while buffer.count < 16384 {
            let chunk: Data? = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                    cont.resume(returning: error == nil ? data : nil)
                }
            }
            guard let chunk, !chunk.isEmpty else { return nil }
            buffer.append(chunk)
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                break
            }
        }
        return String(data: buffer, encoding: .utf8)
    }

    private static func send(_ c: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            c.send(content: data, completion: .contentProcessed { cont.resume(returning: $0 == nil) })
        }
    }

    private static func closed(_ c: NWConnection) -> Bool {
        switch c.state {
        case .cancelled, .failed:
            return true
        default:
            return false
        }
    }

    private static func serve(_ c: NWConnection, _ torrent: SatoriTorrent) async {
        guard let request = await readRequest(c) else { return }
        let lines = request.components(separatedBy: "\r\n")
        let method = lines.first?.split(separator: " ").first.map(String.init) ?? "GET"
        var range: String?
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("range:") {
                range = line.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        let size = torrent.selectedFileSize()
        guard size > 0, let path = torrent.selectedFilePath() else {
            _ = await send(c, Data("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
            return
        }
        var start: Int64 = 0
        var end: Int64 = size - 1
        var partial = false
        if let range, range.lowercased().hasPrefix("bytes=") {
            let spec = range.dropFirst("bytes=".count).split(separator: ",").first.map(String.init) ?? ""
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                if parts[0].isEmpty, let tail = Int64(parts[1]) {
                    start = max(0, size - tail)
                } else if let a = Int64(parts[0]) {
                    start = a
                    if let b = Int64(parts[1]) {
                        end = min(b, size - 1)
                    }
                }
                partial = true
            }
        }
        guard start >= 0, start <= end else {
            _ = await send(c, Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(size)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
            return
        }
        let type = (path as NSString).pathExtension.lowercased() == "mp4" ? "video/mp4" : "video/x-matroska"
        var head = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: \(type)\r\nAccept-Ranges: bytes\r\nContent-Length: \(end - start + 1)\r\nConnection: close\r\n"
        if partial {
            head += "Content-Range: bytes \(start)-\(end)/\(size)\r\n"
        }
        head += "\r\n"
        guard await send(c, Data(head.utf8)), method != "HEAD" else { return }

        var position = start
        var lastPriority = Date.distantPast
        var handle: FileHandle?
        defer { try? handle?.close() }
        while position <= end {
            if closed(c) {
                return
            }
            if Date().timeIntervalSince(lastPriority) > 2 {
                torrent.prioritize(fromOffset: position)
                lastPriority = Date()
            }
            let available = torrent.availableBytes(fromOffset: position)
            if available <= 0 || !FileManager.default.fileExists(atPath: path) {
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
            if handle == nil {
                handle = FileHandle(forReadingAtPath: path)
            }
            let count = Int(min(available, end - position + 1, 512 * 1024))
            guard let handle, (try? handle.seek(toOffset: UInt64(position))) != nil,
                  let data = try? handle.read(upToCount: count), !data.isEmpty else {
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
            guard await send(c, data) else { return }
            position += Int64(data.count)
        }
    }
}

/// One watching session: the release, the torrent, the file, the server, the Jimaku subtitles.
@available(iOS 16.0, *)
@MainActor
final class OnlineWatch: ObservableObject {
    @Published var status = ""
    @Published var busy = false
    @Published var playURL: URL?

    private var torrent: SatoriTorrent?
    private var server: StreamServer?
    private var task: Task<Void, Never>?

    private static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("satori-stream")
    }

    func start(entry: JimakuService.Entry, episode: Int) {
        guard !busy else { return }
        guard let key = JimakuKeychain.read() else {
            status = "Нет ключа Jimaku: добавьте его кнопкой в списке видео"
            return
        }
        stop()
        busy = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run(entry: entry, episode: episode, key: key)
            } catch is CancellationError {
            } catch {
                self.status = error.localizedDescription
                self.teardown()
            }
            self.busy = false
        }
    }

    private func run(entry: JimakuService.Entry, episode: Int, key: String) async throws {
        try? FileManager.default.removeItem(at: Self.root)
        let subs = Self.root.appendingPathComponent("subs")
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)

        let titles = TorrentSearch.searchTitles(entry)
        var releases: [String: TorrentSearch.Release] = [:]
        var failure: Error?
        let season = titles.compactMap { TorrentSearch.seasonNumber($0) }.first ?? 1
        for title in TorrentSearch.queries(titles, season: season) {
            status = "Поиск раздач: \(title)…"
            do {
                for release in try await TorrentSearch.search(title) where TorrentSearch.matches(release.name, titles: titles) {
                    releases[release.magnet] = release
                }
            } catch {
                failure = error
            }
            try Task.checkCancellation()
        }
        guard !releases.isEmpty else {
            throw failure ?? TorrentSearch.Failure(message: "Не найдены релизы с совпадающим названием: " + titles.joined(separator: ", "))
        }
        let candidates = TorrentSearch.ranked(Array(releases.values), episode: episode, season: season)
        guard !candidates.isEmpty else {
            throw TorrentSearch.Failure(message: "Раздачи найдены (\(releases.count)), но серии \(episode) сезона \(season) с раздающими среди них нет")
        }
        // a release without peers or too slow gives way to the next one
        var lastError: Error = TorrentSearch.Failure(message: "Нет раздач")
        for release in candidates.prefix(3) {
            do {
                try await stream(release, entry: entry, episode: episode, key: key, subs: subs)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                CrashTrail.mark("онлайн: \(release.name): \(error.localizedDescription)")
                lastError = error
                teardown()
            }
        }
        throw lastError
    }

    private func stream(_ release: TorrentSearch.Release, entry: JimakuService.Entry, episode: Int, key: String,
                        subs: URL) async throws {
        let chosen = "\(release.name) (\(release.seeders) сидов)"
        status = "Выбрано: \(chosen)"

        let torrent = SatoriTorrent(savePath: Self.root.appendingPathComponent("torrent").path)
        self.torrent = torrent
        guard torrent.addMagnet(release.magnet) else {
            throw TorrentSearch.Failure(message: "Magnet-ссылка не принята")
        }
        var files: [SatoriTorrentFile]?
        for second in 0..<60 {
            files = torrent.files()
            if files != nil { break }
            status = "\(chosen)\nИщу раздающих, список файлов… \(second) с\n\(torrent.diagnostics())"
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard let files else {
            // what the session saw goes to the journal: the next release replaces the status
            CrashTrail.mark("онлайн: нет списка файлов\n" + torrent.diagnostics())
            throw TorrentSearch.Failure(message: "Не удалось получить список файлов\n" + torrent.diagnostics())
        }
        let file = try TorrentSearch.episodeFile(files, episode: episode)
        guard torrent.selectFile(Int32(file.index)) else {
            throw TorrentSearch.Failure(message: "Файл серии не выбран")
        }
        let fileName = (file.path as NSString).lastPathComponent
        let stem = (fileName as NSString).deletingPathExtension

        status = "\(chosen)\nСубтитры Jimaku…"
        let subtitles = await Self.fetchSubtitles(entry: entry, episode: episode, key: key, folder: subs, stem: stem, release: fileName)
        if let problem = subtitles {
            CrashTrail.mark("онлайн: субтитры Jimaku: \(problem)")
        }

        // the start of the file without a gap; «скачано» also counts pieces that are not whole yet
        let need = min(file.size, 8 * 1024 * 1024)
        for second in 0..<120 {
            if torrent.availableBytes(fromOffset: 0) >= need { break }
            // set again every second: a deadline that has passed is not served, and the first pieces were never asked for
            torrent.prioritize(fromOffset: 0)
            status = "\(chosen)\nФайл \(file.size / 1024 / 1024) МБ, скачано \(torrent.downloadedBytes() / 1024 / 1024) МБ, \(torrent.downloadRate() / 1024) КБ/с\n\(torrent.diagnostics())"
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if second == 119 {
                CrashTrail.mark("онлайн: начало серии не скачалось\n" + torrent.diagnostics())
                throw TorrentSearch.Failure(message: "Слишком медленно: начало серии не скачалось за 2 минуты\n" + torrent.diagnostics())
            }
        }
        let server = StreamServer(torrent: torrent)
        guard await server.start() else {
            throw TorrentSearch.Failure(message: "Не удалось запустить локальный сервер")
        }
        self.server = server
        // the path of the address is the real folder of the subtitles: the player looks for «name.ass» next to it
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(server.port)
        components.path = subs.appendingPathComponent(fileName).path
        status = subtitles.map { "Готово, но без субтитров Jimaku: \($0)" } ?? "Готово"
        playURL = components.url
    }

    /// The first Jimaku file with readable lines, saved as «stem.ext» in the folder the player will look in.
    /// nil when it is there, otherwise why not. Jimaku answers slowly from some networks (7 s and more while the
    /// torrent takes the line), so every request gets a second try.
    private static func fetchSubtitles(entry: JimakuService.Entry, episode: Int, key: String, folder: URL,
                                       stem: String, release: String) async -> String? {
        func twice<T>(_ work: () async throws -> T) async throws -> T {
            do {
                return try await work()
            } catch {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return try await work()
            }
        }
        do {
            let files = try await twice { try await JimakuService.files(entry: entry.id, episode: episode, key: key) }
            guard !files.isEmpty else { return "для этой серии файлов нет" }
            for file in JimakuService.pickFiles(files, release: JimakuName.release(release)) {
                let temp = try await twice { try await JimakuService.download(file, key: key) }
                guard !EmbeddedSubtitles.cues(fromFile: temp).isEmpty else { continue }
                let ext = (file.name as NSString).pathExtension.lowercased()
                let dest = folder.appendingPathComponent(stem).appendingPathExtension(ext)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: temp, to: dest)
                return nil
            }
            return "ни один из \(files.count) файлов не подошёл"
        } catch {
            return "нет связи с jimaku.cc (\(error.localizedDescription))"
        }
    }

    private func teardown() {
        server?.stop()
        server = nil
        torrent?.stopAndDelete()
        torrent = nil
        playURL = nil
    }

    /// Stops everything and deletes the downloaded part.
    func stop() {
        task?.cancel()
        task = nil
        teardown()
        try? FileManager.default.removeItem(at: Self.root)
        busy = false
    }
}

/// «Видео» → «+» → «Смотреть онлайн»: a title, an episode, and the episode plays while it downloads.
@available(iOS 16.0, *)
struct OnlineWatchView: View {
    /// Shown by UIKit from the top screen, like FolderPick: SwiftUI presentations set from the «+» menu never opened.
    /// Every step goes to the trail (Настройки → Диагностика → Журнал): the screen never opened on the phone and
    /// there was no log to tell why.
    @MainActor
    static func present(from place: String = "меню") {
        CrashTrail.mark("онлайн: нажато (\(place)), сборка \(DiagnosticChecks.build)")
        Task { @MainActor in
            // the «+» menu is still closing while its button runs
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let top = DiagnosticChecks.topController() else {
                CrashTrail.mark("онлайн: нет окна для показа")
                return
            }
            CrashTrail.mark("онлайн: показываю над \(type(of: top))")
            weak var host: UIViewController?
            let screen = UIHostingController(rootView: NavigationView {
                OnlineWatchView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Закрыть") { host?.dismiss(animated: true) }
                        }
                    }
            }
            .navigationViewStyle(.stack))
            host = screen
            top.present(screen, animated: true) {
                CrashTrail.mark("онлайн: показ завершён")
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if screen.view.window == nil {
                CrashTrail.mark("онлайн: экран не попал в окно, сверху \(type(of: DiagnosticChecks.topController() ?? top))")
            }
        }
    }

    @StateObject private var watch = OnlineWatch()
    @State private var query = ""
    @State private var entries: [JimakuService.Entry] = []
    @State private var picked: JimakuService.Entry?
    @State private var episode = 1
    @State private var searching = false
    @State private var searchMessage = ""
    @State private var showAll = false
    @State private var collapsed = false

    private var shownEntries: [JimakuService.Entry] {
        if collapsed, let picked {
            return [picked]
        }
        return showAll ? entries : Array(entries.prefix(4))
    }

    var body: some View {
        List {
            Section {
                TextField("Название аниме", text: $query)
                    .submitLabel(.search)
                    .onSubmit { search() }
                Button(searching ? "Ищу…" : "Найти в Jimaku") { search() }
                    .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
                if !searchMessage.isEmpty {
                    Text(searchMessage).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !entries.isEmpty {
                Section("Что смотрим") {
                    ForEach(shownEntries, id: \.id) { entry in
                        Button {
                            // a tap on the only row opens the list again
                            withAnimation {
                                collapsed = !(collapsed && picked?.id == entry.id)
                                picked = entry
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(entry.english_name ?? entry.name)
                                    if entry.english_name != nil {
                                        Text(entry.name).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if picked?.id == entry.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    if !collapsed && !showAll && entries.count > 4 {
                        Button("Показать ещё \(entries.count - 4)") {
                            withAnimation {
                                showAll = true
                            }
                        }
                    }
                }
            }
            if let picked {
                Section {
                    Stepper("Серия \(episode)", value: $episode, in: 1...999)
                    Button(watch.busy ? "Готовлю…" : "Смотреть") {
                        watch.start(entry: picked, episode: episode)
                    }
                    .disabled(watch.busy)
                }
            }
            if !watch.status.isEmpty {
                Section {
                    Text(watch.status).font(.footnote)
                }
            }
        }
        .navigationTitle("Смотреть онлайн")
        .navigationBarTitleDisplayMode(.inline)
        .background(
            NavigationLink(destination: Group {
                if let url = watch.playURL {
                    NativeVideoPlayerScreen(url: url)
                }
            }, isActive: Binding(get: { watch.playURL != nil },
                                 set: { if !$0 { watch.stop() } })) { EmptyView() }
        )
        .onAppear {
            CrashTrail.mark("онлайн: экран появился")
        }
        .onDisappear {
            if watch.playURL == nil {
                watch.stop()
            }
        }
    }

    private func search() {
        guard let key = JimakuKeychain.read() else {
            searchMessage = "Нет ключа Jimaku: добавьте его кнопкой в списке видео"
            return
        }
        let title = query.trimmingCharacters(in: .whitespaces)
        searching = true
        searchMessage = ""
        Task {
            do {
                // the closest names first: the same as typed, starting with it, holding it
                let wanted = TorrentSearch.norm(title)
                func distance(_ entry: JimakuService.Entry) -> Int {
                    let names = [entry.name, entry.english_name ?? ""].map(TorrentSearch.norm)
                    if names.contains(wanted) { return 0 }
                    if names.contains(where: { $0.hasPrefix(wanted) }) { return 1 }
                    return names.contains(where: { $0.contains(wanted) }) ? 2 : 3
                }
                entries = try await JimakuService.search(title, key: key).enumerated()
                    .sorted { (distance($0.element), $0.offset) < (distance($1.element), $1.offset) }
                    .map { $0.element }
                showAll = false
                collapsed = false
                picked = entries.first
                searchMessage = entries.isEmpty ? "Ничего не найдено" : ""
            } catch {
                searchMessage = "Нет связи с Jimaku"
            }
            searching = false
        }
    }
}

/// Настройки → Диагностика → «Проверки»: each check says what works on this phone. A new check is one more line in
/// `all`.
@available(iOS 16.0, *)
enum DiagnosticChecks {
    /// the run number of the GitHub build (the app version stays the same between builds)
    static let build = "@@BUILD@@"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static let all: [(String, @MainActor () async throws -> String)] = [
        ("Сборка", {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            return "\(version) (сборка \(build)), iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)"
        }),
        ("Свободное место", {
            let values = try URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let free = values.volumeAvailableCapacityForImportantUsage ?? 0
            guard free > 2_000_000_000 else { throw Failure(message: "мало: \(free / 1_000_000) МБ, серии нужно ~1-2 ГБ") }
            return "\(free / 1_000_000_000) ГБ"
        }),
        ("Ключ Jimaku", {
            guard JimakuKeychain.read() != nil else { throw Failure(message: "нет ключа: «+» → «Ключ Jimaku»") }
            return "есть"
        }),
        ("Поиск в Jimaku", {
            guard let key = JimakuKeychain.read() else { throw Failure(message: "нет ключа") }
            let found = try await JimakuService.search("Frieren", key: key)
            guard !found.isEmpty else { throw Failure(message: "ответ пустой") }
            return "найдено \(found.count)"
        }),
        ("Поиск раздач (Nyaa)", {
            let found = try await TorrentSearch.search("Sousou no Frieren")
            guard !found.isEmpty else { throw Failure(message: "ответ пустой") }
            return "найдено \(found.count), лучший: \(found.map { $0.seeders }.max() ?? 0) сидов"
        }),
        ("Подбор раздач (правила)", {
            let cases: [(String, Bool)] = [
                ("скобки в названии", TorrentSearch.matches("[DB] [Oshi no Ko] 3rd Season | [Oshi No Ko] Season 3 [Dual Audio]", titles: ["Oshi no Ko 3rd Season"])),
                ("сборник", TorrentSearch.matches("[Group] Monster (2004) [01-74] [1080p]", titles: ["Monster"])),
                ("чужое название", !TorrentSearch.matches("[Group] Monster Musume - 21", titles: ["Monster"])),
                ("знаки в названии", TorrentSearch.matches("[X] Frieren - Beyond Journey's End S2 - 03", titles: ["Frieren: Beyond Journey's End"])),
                ("сезон в S03E11", TorrentSearch.seasonNumber("Oshi no Ko - S03E11") == 3),
                ("серия", TorrentSearch.episodeNumber("[WF] Oshi no Ko 3rd Season - 06 [BD] (S03E30)") == 6),
            ]
            let failed = cases.filter { !$0.1 }.map { $0.0 }
            guard failed.isEmpty else { throw Failure(message: "не прошли: " + failed.joined(separator: ", ")) }
            return "все \(cases.count)"
        }),
        ("Торрент-движок и локальный сервер", {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("satori-check")
            let torrent = SatoriTorrent(savePath: folder.path)
            defer { torrent.stopAndDelete() }
            let server = StreamServer(torrent: torrent)
            defer { server.stop() }
            guard await server.start() else { throw Failure(message: "сервер не запустился") }
            return "сервер на порту \(server.port)"
        }),
        ("Показ экрана поверх приложения", {
            guard let top = topController() else { throw Failure(message: "нет окна") }
            let probe = UIHostingController(rootView: Text("Проверка показа"))
            top.present(probe, animated: true)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let shown = probe.view.window != nil
            probe.dismiss(animated: true)
            guard shown else { throw Failure(message: "экран не появился над \(type(of: top))") }
            return "работает над \(type(of: top))"
        }),
    ]

    /// The screen on top of the app: modal screens shown by UIKit are presented from it.
    @MainActor
    static func topController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        guard var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController else { return nil }
        while let shown = top.presentedViewController, !shown.isBeingDismissed {
            top = shown
        }
        return top
    }

    @MainActor
    static func runAll() async -> String {
        var lines: [String] = []
        for (name, check) in all {
            do {
                lines.append("✓ \(name): " + (try await check()))
            } catch {
                lines.append("✗ \(name): \(error.localizedDescription)")
            }
        }
        let text = lines.joined(separator: "\n")
        CrashTrail.mark("проверки:\n" + text)
        return text
    }
}

@available(iOS 16.0, *)
struct DiagnosticChecksSection: View {
    @State private var report = ""
    @State private var running = false

    var body: some View {
        Section {
            if !report.isEmpty {
                Text(report)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                Button("Скопировать") {
                    UIPasteboard.general.string = report
                }
            }
            Button(running ? "Проверяю…" : "Запустить проверки") {
                running = true
                Task {
                    report = await DiagnosticChecks.runAll()
                    running = false
                }
            }
            .disabled(running)
            Button("Открыть «Смотреть онлайн» отсюда") {
                OnlineWatchView.present(from: "диагностика")
            }
        } header: {
            Text("Проверки")
        } footer: {
            Text("Результат проверок и шаги «Смотреть онлайн» пишутся в журнал выше.")
        }
    }
}
