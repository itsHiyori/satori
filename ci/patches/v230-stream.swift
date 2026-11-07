
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

    /// The names a release can carry: both names of the Jimaku entry, with and without «Season N».
    static func searchTitles(_ entry: JimakuService.Entry) -> [String] {
        var titles: [String] = []
        for title in [entry.name, entry.english_name].compactMap({ $0 }) {
            let bare = title.replacingOccurrences(
                of: #"\s*(?:\d+(?:st|nd|rd|th)\s+season|season\s*\d+|s\d{1,2})\s*$"#, with: "",
                options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespaces)
            for candidate in [title, bare] where !candidate.isEmpty
                && !titles.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                titles.append(candidate)
            }
        }
        return titles
    }

    /// The release starts with the title; what follows is a number, a season or «batch», not another title.
    static func matches(_ release: String, titles: [String]) -> Bool {
        let clean = release.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        for title in titles {
            guard let range = clean.range(of: title, options: [.anchored, .caseInsensitive]) else {
                continue
            }
            let rest = clean[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " -_.:"))
            if rest.isEmpty || Rx.test(#"^(?:\d|\(|season\b|s\d|batch\b|complete\b)"#, rest) {
                return true
            }
        }
        return false
    }

    static func seasonNumber(_ name: String) -> Int? {
        guard let g = Rx.first(#"(?:\bseason[ ._-]*(\d+)|\b(\d+)(?:st|nd|rd|th) season|(?<![a-z0-9])s(\d{1,2})(?![a-z0-9]))"#, name) else {
            return nil
        }
        return g.dropFirst().compactMap { Int($0) }.first
    }

    /// A batch (or a range) that holds the episode, the most seeded first; without one, a single release of that episode.
    static func best(_ items: [Release], episode: Int, season: Int) -> Release? {
        func seasonOK(_ name: String) -> Bool {
            let s = seasonNumber(name)
            if let s, s != season {
                return false
            }
            return !(season > 1 && s == nil)
        }
        var batches: [Release] = []
        var singles: [Release] = []
        for item in items where seasonOK(item.name) {
            let name = item.name
            let single = Rx.test(#"s\d+e\d+|\s-\s\d{1,3}(?:v\d)?(?:\s|\[|$)"#, name)
            if single {
                let number = Rx.first(#"s\d+e(\d+)|\s-\s(\d{1,3})(?:v\d)?(?:\s|\[|$)"#, name)?.dropFirst().compactMap { Int($0) }.first
                if number == episode {
                    singles.append(item)
                }
                continue
            }
            let ranges = Rx.all(#"(?<!\d)(\d{1,3})\s*[-~–]\s*(\d{1,3})(?!\d)"#, name)
            if !ranges.isEmpty {
                if ranges.contains(where: { (Int($0[1]) ?? 0) <= episode && episode <= (Int($0[2]) ?? 0) }) {
                    batches.append(item)
                }
            } else if Rx.test(#"\b(?:batch|complete)\b|(?<![a-z0-9])s\d{1,2}(?![a-z0-9])"#, name) {
                batches.append(item)
            }
        }
        return (batches.max { $0.seeders < $1.seeders }) ?? (singles.max { $0.seeders < $1.seeders })
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
        for title in titles {
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
        let season = titles.compactMap { TorrentSearch.seasonNumber($0) }.first ?? 1
        guard let release = TorrentSearch.best(Array(releases.values), episode: episode, season: season) else {
            throw TorrentSearch.Failure(message: "Не найден сборник или релиз для серии \(episode)")
        }
        status = "Выбрано (\(release.seeders) сидов): \(release.name)"

        let torrent = SatoriTorrent(savePath: Self.root.appendingPathComponent("torrent").path)
        self.torrent = torrent
        guard torrent.addMagnet(release.magnet) else {
            throw TorrentSearch.Failure(message: "Magnet-ссылка не принята")
        }
        var files: [SatoriTorrentFile]?
        for second in 0..<120 {
            files = torrent.files()
            if files != nil { break }
            status = "Ищу раздающих, список файлов… \(second) с, пиров: \(torrent.peerCount())"
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard let files else {
            throw TorrentSearch.Failure(message: "Не удалось получить список файлов: проверьте раздающих")
        }
        let file = try TorrentSearch.episodeFile(files, episode: episode)
        guard torrent.selectFile(Int32(file.index)) else {
            throw TorrentSearch.Failure(message: "Файл серии не выбран")
        }
        let fileName = (file.path as NSString).lastPathComponent
        let stem = (fileName as NSString).deletingPathExtension

        status = "Субтитры Jimaku…"
        let found = await Self.fetchSubtitles(entry: entry, episode: episode, key: key, folder: subs, stem: stem, release: fileName)

        let need = min(file.size, 8 * 1024 * 1024)
        for second in 0..<180 {
            let have = torrent.availableBytes(fromOffset: 0)
            if have >= need { break }
            status = "Буфер: \(have / 1024 / 1024) из \(need / 1024 / 1024) МБ, \(torrent.downloadRate() / 1024) КБ/с, пиров: \(torrent.peerCount())"
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if second == 179 {
                throw TorrentSearch.Failure(message: "Слишком медленно: нет раздающих")
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
        status = found ? "Готово" : "Готово, но субтитров Jimaku для этой серии нет"
        playURL = components.url
    }

    /// The first Jimaku file with readable lines, saved as «stem.ext» in the folder the player will look in.
    private static func fetchSubtitles(entry: JimakuService.Entry, episode: Int, key: String, folder: URL,
                                       stem: String, release: String) async -> Bool {
        do {
            let files = try await JimakuService.files(entry: entry.id, episode: episode, key: key)
            for file in JimakuService.pickFiles(files, release: JimakuName.release(release)) {
                let temp = try await JimakuService.download(file, key: key)
                guard !EmbeddedSubtitles.cues(fromFile: temp).isEmpty else { continue }
                let ext = (file.name as NSString).pathExtension.lowercased()
                let dest = folder.appendingPathComponent(stem).appendingPathExtension(ext)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: temp, to: dest)
                return true
            }
        } catch {
        }
        return false
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
    @StateObject private var watch = OnlineWatch()
    @State private var query = ""
    @State private var entries: [JimakuService.Entry] = []
    @State private var picked: JimakuService.Entry?
    @State private var episode = 1
    @State private var searching = false
    @State private var searchMessage = ""

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
                    ForEach(entries, id: \.id) { entry in
                        Button {
                            picked = entry
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
                entries = try await JimakuService.search(title, key: key)
                picked = entries.first
                searchMessage = entries.isEmpty ? "Ничего не найдено" : ""
            } catch {
                searchMessage = "Нет связи с Jimaku"
            }
            searching = false
        }
    }
}
