import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Торренты и файлы по прямым ссылкам: aria2c

/// Торренты и файлы (zip, dmg, pdf…) качает aria2c — по процессу на загрузку. Пауза — остановка процесса: aria2c сохраняет
/// ход в «<имя>.aria2» рядом с файлами и при следующем запуске с теми же параметрами продолжает с места.
enum Aria2 {
    /// Свой, из приложения (собран без c-ares — DNS системный); Homebrew-версия — если своего нет (сборка без него).
    static var path: String? {
        let own = ToolFolder.bundled + "/aria2c"
        return FileManager.default.isExecutableFile(atPath: own) ? own : Tools.find("aria2c")
    }

    /// Английский вывод (его разбираем) и системный DNS: встроенный в aria2c на macOS не находит серверы.
    static var environment: [String: String] {
        var env = Tools.environment
        env["LC_ALL"] = "C"
        env["LANG"] = "C"
        return env
    }

    /// У своего aria2c встроенного DNS нет вовсе, и флага он не знает; Homebrew-версии его нужно выключать.
    static var common: [String] {
        (path.map(ToolFolder.owns) == true ? [] : ["--async-dns=false"]) + commonFlags
    }

    private static let commonFlags = ["--enable-color=false", "--console-log-level=warn",
                         "--show-console-readout=false", "--summary-interval=1",
                         "--stop-with-process=\(ProcessInfo.processInfo.processIdentifier)"]

    static let support = NSHomeDirectory() + "/Library/Application Support/DownMax"
    static let torrentsFolder = support + "/torrents"

    /// Список файлов торрента: `aria2c -S файл.torrent`.
    static func info(_ torrent: String) -> TorrentInfo? {
        guard let aria2 = path else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: aria2)
        p.arguments = ["-S", torrent]
        p.environment = environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var name = "", hash = ""
        var files: [TorrentFile] = []
        var pending: (Int, String)?
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("Name: ") { name = String(line.dropFirst(6)) }
            if line.hasPrefix("Info Hash: ") { hash = String(line.dropFirst(11)) }
            // «  1|./Папка/файл» и следующей строкой «   |639MiB (670,040,064)»
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let left = parts[0].trimmingCharacters(in: .whitespaces)
            if let index = Int(left) {
                var path = String(parts[1])
                if path.hasPrefix("./") { path.removeFirst(2) }
                pending = (index, path)
            } else if left.isEmpty, let (index, path) = pending,
                      let open = parts[1].lastIndex(of: "("), let close = parts[1].lastIndex(of: ")") {
                let digits = parts[1][parts[1].index(after: open)..<close].filter(\.isNumber)
                files.append(TorrentFile(index: index, path: path, size: Int64(digits) ?? 0))
                pending = nil
            }
        }
        guard !files.isEmpty else { return nil }
        return TorrentInfo(name: name.isEmpty ? files[0].path : name, hash: hash.lowercased(), files: files, torrent: torrent)
    }

    /// «12MiB», «1.6KiB», «0B» → байты.
    static func bytes(_ s: Substring) -> Double? {
        let units: [(String, Double)] = [("TiB", 1_099_511_627_776), ("GiB", 1_073_741_824), ("MiB", 1_048_576), ("KiB", 1024), ("B", 1)]
        for (unit, k) in units where s.hasSuffix(unit) {
            return Double(s.dropLast(unit.count)).map { $0 * k }
        }
        return nil
    }
}

struct TorrentFile: Identifiable, Codable {
    let index: Int
    let path: String
    let size: Int64
    var id: Int { index }
}

struct TorrentInfo {
    let name: String
    let hash: String
    let files: [TorrentFile]
    let torrent: String

    /// Что появится в папке загрузки: папка торрента или единственный файл.
    var rootName: String { files[0].path.split(separator: "/").first.map(String.init) ?? name }
}

// MARK: - Один торрент

final class TorrentJob: ObservableObject, Identifiable {
    enum State: String, Codable { case queued, downloading, paused, seeding, done, failed }

    /// Что хранится между запусками (Application Support/DownMax/torrents.json).
    struct Record: Codable {
        let id: UUID
        let name: String
        let hash: String
        let torrent: String
        let folder: String
        let root: String
        var selected: [Int]?   // nil — все файлы
        var size: Int64
        /// Раздавать, пока пользователь не остановит (после загрузки или кнопкой «Раздавать» у готового).
        var seed: Bool
        var state: State
        /// Сколько скачано к последней остановке: «12 МБ из 756 МБ» и доля.
        var amounts: String? = nil
        var progress: Double? = nil
        /// Файл по прямой ссылке (не торрент): адрес, откуда качать.
        var link: String? = nil
        /// Когда добавлен (у записей до 2.0 — нет).
        var added: Date? = nil
        /// Сколько отдано за прошлые запуски aria2c (каждый запуск считает с нуля).
        var uploaded: Int64? = nil
        /// Когда загрузка завершилась (раздача после неё дату не меняет).
        var finished: Date? = nil
        /// Почему остановилась с ошибкой: понятная фраза для строки и исходная строка aria2c для подробностей.
        var failure: String? = nil
        var error: String? = nil
        /// Откуда пришла ссылка или файл (для статистики): field, chrome, safari, iphone, torrent_file.
        var origin: String? = nil
    }

    var record: Record
    @Published var state: State
    @Published var progress: Double = 0
    @Published var detail = ""
    @Published var filesDeleted = false
    // Ход по последней строке aria2c: скорости, отдано за этот запуск, участники.
    @Published var downSpeed: Double = 0
    @Published var upSpeed: Double = 0
    @Published var sessionUploaded: Double = 0
    @Published var peers: Int?
    @Published var seeders: Int?

    private var process: Process?
    private var stopping: State?   // во что перейти, когда процесс остановится
    private var lastError: String?

    var id: UUID { record.id }
    var isFile: Bool { record.link != nil }
    var name: String { record.name }
    var target: String { record.folder + "/" + record.root }
    var isActive: Bool { process != nil }
    /// Отдано всего, за все запуски.
    var uploaded: Double { Double(record.uploaded ?? 0) + sessionUploaded }
    /// Рейтинг — сколько отдано относительно скачанного: «0,52».
    var ratio: String {
        guard record.size > 0 else { return "0" }
        return String(format: "%.2f", uploaded / Double(record.size)).replacingOccurrences(of: ".", with: ",")
    }
    /// Готовый торрент можно раздавать, пока на месте его файлы и торрент-файл.
    var canSeed: Bool {
        !isFile && state == .done && !filesDeleted
            && FileManager.default.fileExists(atPath: target) && FileManager.default.fileExists(atPath: record.torrent)
    }

    init(record: Record) {
        self.record = record
        self.state = record.state
        switch record.state {
        case .paused: detail = (["Пауза", record.amounts].compactMap { $0 }).joined(separator: " · "); progress = record.progress ?? 0
        case .done: detail = "Готово · \(bytes(Double(record.size)))"; progress = 1
        case .failed: detail = record.failure ?? "Ошибка"
        case .queued: detail = (["В очереди", record.amounts].compactMap { $0 }).joined(separator: " · "); progress = record.progress ?? 0
        default: detail = record.link != nil ? "Подключаюсь…" : "Ищу участников раздачи…"
        }
    }

    /// seeding — запуск раздачи готового торрента (кнопка «Раздавать» или перезапуск приложения во время раздачи).
    func start(seeding: Bool = false) {
        guard process == nil else { return }
        guard let aria2 = Aria2.path else {
            fail("Не найден aria2c. Установите его в «Компонентах» внизу окна.")
            return
        }
        var args = Aria2.common + ["--dir=" + record.folder, "--continue=true", "--file-allocation=none"]
        if let link = record.link {
            // Файл — в 8 потоков; имя выбрано заранее (см. FileLink), чужой файл не перезаписываем.
            args += ["--out=" + record.root, "--max-connection-per-server=8", "--split=8", "--min-split-size=1M",
                     "--auto-file-renaming=false", "--user-agent=" + FileLink.userAgent, link]
        } else {
            args += ["--bt-save-metadata=false", "--follow-torrent=false",
                     "--dht-file-path=" + Aria2.support + "/dht.dat"]
            if let selected = record.selected { args.append("--select-file=" + selected.map(String.init).joined(separator: ",")) }
            // 0.0 — раздавать без ограничения, пока пользователь не остановит
            args += record.seed ? ["--seed-ratio=0.0"] : ["--seed-time=0"]
            // Файла хода «.aria2» нет, а файлы есть — торрент уже скачан (aria2c удаляет .aria2 в конце):
            // сверить куски с диском, иначе aria2c начнёт качать заново.
            let fm = FileManager.default
            if fm.fileExists(atPath: target) && !fm.fileExists(atPath: target + ".aria2") {
                args.append("--check-integrity=true")
            }
            args.append(record.torrent)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: aria2)
        p.arguments = args
        p.environment = Aria2.environment
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let splitter = LineSplitter { line in DispatchQueue.main.async { self.handle(line) } }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; splitter.flush() } else { splitter.append(data) }
        }
        p.terminationHandler = { proc in
            DispatchQueue.main.async { self.finished(proc.terminationStatus) }
        }
        lastError = nil
        record.failure = nil
        record.error = nil
        stopping = nil
        do {
            try p.run()
            process = p
            if seeding || state == .seeding {
                setState(.seeding)
                detail = "Проверяю файлы перед раздачей…"
            } else {
                setState(.downloading)
                if progress == 0 { detail = isFile ? "Подключаюсь…" : "Ищу участников раздачи…" }
            }
            DockProgress.shared.start()
        } catch {
            record.error = error.localizedDescription
            fail("Не удалось запустить aria2c. Переустановите его в «Компонентах» внизу окна.")
        }
    }

    /// Нет места в очереди (лимит очереди) — ждать; запустит DownloadQueue.
    func enqueue() {
        detail = (["В очереди", record.amounts].compactMap { $0 }).joined(separator: " · ")
        setState(.queued)
    }

    /// Лимит уменьшили — вернуть в очередь (как пауза, но ждать своей очереди).
    func requeue() {
        guard state == .downloading else { return }
        stop(then: .queued)
    }

    func pause() {
        Stats.send("pause", ["kind": isFile ? "file" : "torrent"])
        stop(then: .paused)
    }

    /// Пауза для ждущего в очереди (групповая «Пауза»): не запускать, пока не продолжат.
    func hold() {
        guard state == .queued else { return }
        detail = (["Пауза", record.amounts].compactMap { $0 }).joined(separator: " · ")
        setState(.paused)
    }

    func stopSeeding() {
        record.seed = false
        stop(then: .done)
    }

    /// «Раздавать» у готового торрента: aria2c сверяет файлы с торрентом и раздаёт, пока не остановят.
    func startSeeding() {
        guard canSeed else { return }
        Stats.send("seed")
        record.seed = true
        start(seeding: true)
    }

    /// При выходе из приложения: остановить, но запомнить как идущую — при запуске продолжится.
    func stopForQuit() -> Process? {
        guard let p = process else { return nil }
        stopping = state
        p.terminate()
        return p
    }

    private func stop(then next: State) {
        guard let p = process else { return setState(next) }
        stopping = next
        p.terminate()
    }

    private func finished(_ status: Int32) {
        process = nil
        record.uploaded = Int64(uploaded)
        sessionUploaded = 0
        downSpeed = 0
        upSpeed = 0
        peers = nil
        seeders = nil
        TorrentManager.shared.save()
        if let next = stopping {
            stopping = nil
            if TorrentManager.shared.quitting { return }
            setState(next)
            if next == .paused { detail = (["Пауза", record.amounts].compactMap { $0 }).joined(separator: " · ") }
            if next == .queued { detail = (["В очереди", record.amounts].compactMap { $0 }).joined(separator: " · ") }
            if next == .done { markDone() }
            return
        }
        if status == 0 {
            markDone()
        } else {
            record.error = lastError ?? "aria2c завершился с кодом \(status)"
            fail(Failure.aria2(status, raw: lastError))
            Stats.send("download_failed", statProps.merging(["error": "aria2_\(status)"]) { $1 })
        }
    }

    private func markDone() {
        // У файла размер мог быть неизвестен заранее — берём настоящий.
        if isFile, let size = (try? FileManager.default.attributesOfItem(atPath: target))?[.size] as? Int64 {
            record.size = size
        }
        if record.finished == nil {
            record.finished = Date()  // раздача после загрузки сюда возвращается ещё раз — «готово» считается однажды
            var props = statProps
            if let added = record.added { props["duration_s"] = Date().timeIntervalSince(added) }
            props["size_mb"] = Double(record.size) / 1_000_000
            Stats.send("download_done", props)
        }
        setState(.done)
        progress = 1
        detail = "Готово · \(bytes(Double(record.size)))"
        removeUnselected()
    }

    /// Куски торрента общие для соседних файлов, поэтому aria2c создаёт и невыбранные файлы —
    /// «пустые» (на диске немного, а размер полный). После загрузки они не нужны.
    private func removeUnselected() {
        guard let selected = record.selected else { return }
        let (torrent, folder, root) = (record.torrent, record.folder, record.root)
        DispatchQueue.global(qos: .utility).async {
            guard let info = Aria2.info(torrent) else { return }
            let fm = FileManager.default
            for file in info.files where !selected.contains(file.index) {
                var path = folder + "/" + file.path
                try? fm.removeItem(atPath: path)
                // и опустевшие папки, но не выше папки торрента
                while true {
                    path = (path as NSString).deletingLastPathComponent
                    guard path.hasPrefix(folder + "/" + root), path != folder,
                          (try? fm.contentsOfDirectory(atPath: path))?.isEmpty == true else { break }
                    try? fm.removeItem(atPath: path)
                }
            }
        }
    }

    private func fail(_ text: String) {
        detail = text
        record.failure = text
        setState(.failed)
    }

    private func setState(_ s: State) {
        TorrentManager.shared.objectWillChange.send()  // окно показывает «Очистить завершённые» по состояниям
        let old = state
        state = s
        record.state = s
        TorrentManager.shared.save()
        if old != s { DownloadQueue.tick() }  // освободилось место — запустить ждущие
    }

    /// «[#a1b2c3 12MiB/756MiB(1%) CN:45 SD:21 DL:1.6MiB ETA:7m36s]»
    /// «[#a1b2c3 SEED(0.3) CN:3 SD:0 UL:120KiB(80MiB)]»
    private func handle(_ line: String) {
        if line.contains("[ERROR]") || line.hasPrefix("Exception") {
            lastError = line.components(separatedBy: " - ").last?.trimmingCharacters(in: .whitespaces)
            return
        }
        guard line.hasPrefix("[#"), line.hasSuffix("]"), process != nil, stopping == nil else { return }
        let tokens = line.dropFirst().dropLast().split(separator: " ").dropFirst()
        var fields: [Substring: Substring] = [:]
        for t in tokens {
            if let colon = t.firstIndex(of: ":") { fields[t[..<colon]] = t[t.index(after: colon)...] }
        }
        peers = fields["CN"].flatMap { Int($0) }
        seeders = fields["SD"].flatMap { Int($0) }
        downSpeed = fields["DL"].flatMap { Aria2.bytes($0) } ?? 0
        // «UL:120KiB(80MiB)» — скорость отдачи и сколько отдано за этот запуск
        if let ul = fields["UL"], let open = ul.firstIndex(of: "("), ul.hasSuffix(")") {
            upSpeed = Aria2.bytes(ul[..<open]) ?? 0
            sessionUploaded = Aria2.bytes(ul[ul.index(after: open)..<ul.index(before: ul.endIndex)]) ?? sessionUploaded
        } else {
            upSpeed = 0
        }
        let peersText = isFile ? nil : peers.map { "участников: \($0)" }

        if tokens.contains(where: { $0.hasPrefix("SEED(") }) {
            if state != .seeding { setState(.seeding) }
            progress = 1
            detail = ["Раздаю", "↑ \(bytes(upSpeed))/с", "отдано \(bytes(uploaded))", "рейтинг \(ratio)", peersText]
                .compactMap { $0 }.joined(separator: " · ")
            return
        }
        // Раздача готового торрента начинается со сверки файлов — строки хода в это время не про загрузку.
        if state == .seeding {
            detail = "Проверяю файлы перед раздачей…"
            return
        }
        guard let amounts = tokens.first(where: { $0.contains("/") && $0.hasSuffix("%)") }),
              let slash = amounts.firstIndex(of: "/"), let open = amounts.firstIndex(of: "("),
              let done = Aria2.bytes(amounts[..<slash]),
              let total = Aria2.bytes(amounts[amounts.index(after: slash)..<open]) else { return }
        if total > 0 { progress = min(done / total, 1) }
        record.progress = progress
        record.amounts = "\(bytes(done)) из \(bytes(total))"
        let speed = downSpeed
        if speed == 0 {
            let waiting = isFile ? "подключаюсь…" : "ищу участников раздачи…"
            detail = done == 0 ? waiting.prefix(1).uppercased() + waiting.dropFirst() : (record.amounts ?? "") + " · " + waiting
            return
        }
        var parts = [record.amounts ?? "", "↓ \(bytes(speed))/с"]
        if upSpeed > 0 { parts.append("↑ \(bytes(upSpeed))/с") }
        if let eta = fields["ETA"] { parts.append("осталось " + Self.eta(eta)) }
        if let peersText { parts.append(peersText) }
        detail = parts.joined(separator: " · ")
    }

    /// «1h2m3s» → «1:02:03», «7m36s» → «7:36»
    private static func eta(_ s: Substring) -> String {
        var h = 0, m = 0, sec = 0, n = 0
        for c in s {
            if let d = c.wholeNumberValue { n = n * 10 + d; continue }
            switch c { case "h": h = n; case "m": m = n; case "s": sec = n; default: break }
            n = 0
        }
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Остановить и убрать недокачанное: файлы торрента — в Корзину, файл хода aria2c — насовсем.
    func discard(trashFiles: Bool) {
        let cleanup = {
            try? FileManager.default.removeItem(atPath: self.target + ".aria2")
            if trashFiles, FileManager.default.fileExists(atPath: self.target) {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: self.target), resultingItemURL: nil)
            }
        }
        if let p = process {
            stopping = .paused
            p.terminationHandler = { _ in DispatchQueue.main.async { self.process = nil; cleanup() } }
            p.terminate()
        } else {
            cleanup()
        }
    }
}

private func bytes(_ v: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file)
}

// MARK: - Список торрентов

final class TorrentManager: ObservableObject {
    static let shared = TorrentManager()
    @Published var torrents: [TorrentJob] = []
    /// Торрент, для которого открыто окно «Новая загрузка».
    @Published var pending: PendingTorrent? {
        // окно закрыли (скачать или отмена) — открыть следующую magnet-ссылку из очереди
        didSet { if pending == nil, oldValue != nil { openNextQueued() } }
    }
    /// magnet-ссылки, пришедшие пачкой: окно выбора файлов — одно, поэтому по очереди.
    private var queuedMagnets: [(link: String, origin: String)] = []

    func enqueue(magnet: String, origin: String) {
        if pending == nil && loading == nil {
            open(magnet: magnet, origin: origin)
        } else {
            queuedMagnets.append((magnet, origin))
        }
    }

    private func openNextQueued() {
        guard !queuedMagnets.isEmpty else { return }
        let next = queuedMagnets.removeFirst()
        DispatchQueue.main.async { self.open(magnet: next.link, origin: next.origin) }
    }
    /// Сообщение пользователю — окном-вопросом по центру, даже если главное окно закрыто.
    @Published var alert: String? {
        didSet { if let alert { DispatchQueue.main.async { self.alert = nil; Ask.run(alert) } } }
    }
    var quitting = false

    private static let listURL = URL(fileURLWithPath: Aria2.support + "/torrents.json")

    var downloading: [TorrentJob] { torrents.filter { $0.state == .downloading } }

    /// При запуске: список из прошлого раза, идущие загрузки продолжаются.
    func restore() {
        guard let data = try? Data(contentsOf: Self.listURL),
              let records = try? JSONDecoder().decode([TorrentJob.Record].self, from: data) else { return }
        torrents = records.map(TorrentJob.init)
        // раздачи — сразу (в лимит не входят), загрузки — в очередь по лимиту
        torrents.filter { $0.state == .seeding }.forEach { $0.start(seeding: true) }
        torrents.filter { $0.state == .downloading }.forEach { $0.enqueue() }
        DownloadQueue.tick()
    }

    /// Как у видео: готовые файлы удалили мимо приложения — «Файлов нет на диске», без «Открыть» и «Раздавать».
    func checkFiles() {
        for job in torrents where job.state == .done {
            let missing = !FileManager.default.fileExists(atPath: job.target)
            guard job.filesDeleted != missing else { continue }
            job.filesDeleted = missing
            job.detail = missing ? (job.isFile ? "Файла нет на диске" : "Файлов нет на диске") : "Готово · \(bytes(Double(job.record.size)))"
        }
    }

    func save() {
        try? FileManager.default.createDirectory(atPath: Aria2.support, withIntermediateDirectories: true)
        let records = torrents.map(\.record)
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: Self.listURL) }
    }

    func stopAllForQuit() {
        quitting = true
        let all = torrents.compactMap { $0.stopForQuit() }
        let deadline = Date().addingTimeInterval(3)
        while all.contains(where: \.isRunning) && Date() < deadline { usleep(50_000) }
        save()
    }

    // Откуда приходят торренты: magnet-ссылка (браузер, поле ввода) или .torrent (Finder, перетаскивание, ⌘O).

    /// Откуда пришёл торрент, который сейчас в окне «Новая загрузка» (для статистики).
    private var pendingOrigin = "field"

    func open(magnet: String, origin: String) {
        guard ready() else { return }
        pendingOrigin = origin
        let p = PendingTorrent()
        pending = p  // пока идёт список файлов от участников — окно с «Получаю список файлов…» и «Отменой»
        autoStart(p)
        p.fetchMetadata(magnet: magnet)
    }

    /// Файл, который DownMax сам подхватил в «Загрузках» (скачал браузер): после добавления — в Корзину.
    private var pendingBrowserFile: String?

    func open(torrentFile url: URL, fromBrowser: Bool = false) {
        guard ready() else { return }
        pendingOrigin = fromBrowser ? "browser" : "torrent_file"
        pendingBrowserFile = fromBrowser ? url.path : nil
        let p = PendingTorrent()
        if autoStart(p) {
            loading = p  // файл читается за доли секунды — окно не показываем вовсе
        } else {
            pending = p
        }
        p.load(file: url.path)
    }

    /// «Качать без выбора файлов» (переключатель в «Компонентах»): все файлы, папка «Сохранять в», без раздачи.
    static var skipSelection: Bool {
        get { UserDefaults.standard.bool(forKey: "torrentSkipSelection") }
        set { UserDefaults.standard.set(newValue, forKey: "torrentSkipSelection") }
    }
    private var loading: PendingTorrent?

    @discardableResult
    private func autoStart(_ p: PendingTorrent) -> Bool {
        guard Self.skipSelection else { return false }
        p.onInfo = { [weak self, weak p] info in
            guard let self, let p else { return }
            let folder = UserDefaults.standard.string(forKey: "folder") ?? NSHomeDirectory() + "/Downloads"
            self.add(info, selected: Set(info.files.map(\.index)), folder: folder, seed: false)
            p.cancel()  // временная папка magnet больше не нужна (торрент уже скопирован)
            if self.pending === p { self.pending = nil }
            if self.loading === p { self.loading = nil }
        }
        p.onError = { [weak self, weak p] text in
            guard let self, let p else { return }
            if self.pending === p { self.pending = nil }
            if self.loading === p { self.loading = nil }
            self.alert = text
        }
        return true
    }

    func chooseTorrentFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.prompt = "Открыть"
        if panel.runModal() == .OK, let u = panel.url { open(torrentFile: u) }
    }

    func ready() -> Bool {
        guard Aria2.path != nil else {
            alert = "Для торрентов и файлов нужен aria2c. Установите его в «Компонентах» внизу окна."
            return false
        }
        pending?.cancel()
        return true
    }

    /// «Скачать» в окне «Новая загрузка».
    func add(_ info: TorrentInfo, selected: Set<Int>, folder: String, seed: Bool) {
        if let same = torrents.first(where: { !info.hash.isEmpty && $0.record.hash == info.hash }) {
            alert = "Этот торрент уже в списке: «\(same.name)»."
            return
        }
        let id = UUID()
        try? FileManager.default.createDirectory(atPath: Aria2.torrentsFolder, withIntermediateDirectories: true)
        let stored = Aria2.torrentsFolder + "/\(id.uuidString).torrent"
        do {
            try FileManager.default.copyItem(atPath: info.torrent, toPath: stored)
        } catch {
            alert = "Не удалось сохранить торрент-файл: \(error.localizedDescription)"
            return
        }
        let all = selected.count == info.files.count
        let size = info.files.filter { selected.contains($0.index) }.reduce(0) { $0 + $1.size }
        let record = TorrentJob.Record(id: id, name: info.name, hash: info.hash, torrent: stored, folder: folder,
                                       root: info.rootName, selected: all ? nil : selected.sorted(),
                                       size: size, seed: seed, state: DownloadQueue.hasSlot ? .downloading : .queued,
                                       added: Date(), origin: pendingOrigin)
        let job = TorrentJob(record: record)
        torrents.insert(job, at: 0)
        save()
        Stats.send("download_start", job.statProps)
        if seed { Stats.send("seed") }
        if record.state == .downloading { job.start() }
        // копия торрента уже у DownMax — скачанный браузером файл в «Загрузках» больше не нужен
        if let file = pendingBrowserFile, file == info.torrent {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: file), resultingItemURL: nil)
        }
        pendingBrowserFile = nil
    }

    /// Файл по прямой ссылке (после проверки FileLink.detect).
    func add(file: FileLink.Info, folder: String, origin: String) {
        if let same = torrents.first(where: { $0.record.link == file.url && $0.state != .done }) {
            alert = "Этот файл уже качается: «\(same.name)»."
            return
        }
        let ext = (file.name as NSString).pathExtension
        let base = folder + "/" + (ext.isEmpty ? file.name : (file.name as NSString).deletingPathExtension)
        let path = DownloadManager.uniquePath(base, ext: ext.isEmpty ? nil : ext)
        let name = (path as NSString).lastPathComponent
        let record = TorrentJob.Record(id: UUID(), name: name, hash: "", torrent: "", folder: folder, root: name,
                                       selected: nil, size: file.size ?? 0, seed: false,
                                       state: DownloadQueue.hasSlot ? .downloading : .queued,
                                       link: file.url, added: Date(), origin: origin)
        let job = TorrentJob(record: record)
        torrents.insert(job, at: 0)
        save()
        Stats.send("download_start", job.statProps)
        if record.state == .downloading { job.start() }
    }

    func remove(_ job: TorrentJob) {
        if !job.isFile { try? FileManager.default.removeItem(atPath: job.record.torrent) }
        torrents.removeAll { $0.id == job.id }
        save()
    }

    /// Крестик у незавершённого торрента: спросить, что делать с недокачанным.
    func cancel(_ job: TorrentJob) {
        let answer = Ask.run("Отменить загрузку «\(job.name)»?",
                             "Недокачанные файлы можно переместить в Корзину или оставить в папке загрузки.",
                             buttons: ["В Корзину", "Оставить файлы", "Отмена"])
        guard answer != 2 else { return }
        Stats.send("download_cancelled", job.statProps)
        job.discard(trashFiles: answer == 0)
        remove(job)
    }

    func clearFinished() {
        torrents.filter { $0.state == .done || $0.state == .failed }.forEach(remove)
    }
}

// MARK: - Окно «Новая загрузка»: список файлов торрента

final class PendingTorrent: ObservableObject, Identifiable {
    let id = UUID()
    @Published var info: TorrentInfo?
    @Published var error: String?
    /// «Качать без выбора файлов»: список файлов получен — добавить сразу, без окна; ошибка — показать сообщением.
    var onInfo: ((TorrentInfo) -> Void)?
    var onError: ((String) -> Void)?
    private var process: Process?
    private var temp: String?

    /// Для magnet-ссылки список файлов приходит от участников раздачи — это секунды, а бывает и дольше.
    func fetchMetadata(magnet: String) {
        guard let aria2 = Aria2.path else { return }
        let folder = TempFiles.folder(for: id)
        temp = folder
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: aria2)
        p.arguments = Aria2.common + ["--bt-metadata-only=true", "--bt-save-metadata=true", "--follow-torrent=false",
                                      "--summary-interval=0", "--dir=" + folder,
                                      "--dht-file-path=" + Aria2.support + "/dht.dat", magnet]
        p.environment = Aria2.environment
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let file = (try? FileManager.default.contentsOfDirectory(atPath: folder))?
                .first { $0.hasSuffix(".torrent") }
            let info = file.flatMap { Aria2.info(folder + "/" + $0) }
            DispatchQueue.main.async {
                guard self.process === proc else { return }  // отменено
                self.process = nil
                if let info { self.info = info; self.onInfo?(info) } else { self.fail("Не удалось получить список файлов по magnet-ссылке.") }
            }
        }
        do {
            try FileManager.default.createDirectory(atPath: Aria2.support, withIntermediateDirectories: true)
            try p.run()
            process = p
        } catch {
            self.error = "Не удалось запустить aria2c: \(error.localizedDescription)"
        }
    }

    private func fail(_ text: String) {
        if let onError { onError(text) } else { error = text }
    }

    func load(file: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let info = Aria2.info(file)
            DispatchQueue.main.async {
                if let info { self.info = info; self.onInfo?(info) } else { self.fail("Это не торрент-файл или он повреждён.") }
            }
        }
    }

    func cancel() {
        let p = process
        process = nil
        p?.terminate()
        if let temp { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { TempFiles.remove(temp) } }
    }
}

/// Строка дерева файлов: папка или файл торрента.
private struct TreeNode: Identifiable {
    let id: String          // путь внутри торрента
    let name: String
    let depth: Int
    let isFolder: Bool
    let size: Int64
    let indices: [Int]      // файлы внутри (у файла — он сам)
}

/// Дерево из путей файлов торрента.
private final class TreeBuilder {
    var children: [String: TreeBuilder] = [:]
    var fileIndex: Int?
    var size: Int64 = 0
    var indices: [Int] = []

    init(_ files: [TorrentFile]) {
        for f in files { add(f, f.path.split(separator: "/").map(String.init)[...]) }
    }
    private init() {}

    private func add(_ f: TorrentFile, _ parts: ArraySlice<String>) {
        size += f.size
        indices.append(f.index)
        guard let first = parts.first else { fileIndex = f.index; return }
        let child = children[first] ?? TreeBuilder()
        children[first] = child
        child.add(f, parts.dropFirst())
    }

    /// Папки перед файлами, внутри — по имени; содержимое свёрнутых папок пропускается.
    func rows(path: String = "", depth: Int = 0, collapsed: Set<String>) -> [TreeNode] {
        let sorted = children.sorted { a, b in
            let (fa, fb) = (a.value.fileIndex == nil, b.value.fileIndex == nil)
            return fa != fb ? fa : a.key.localizedStandardCompare(b.key) == .orderedAscending
        }
        return sorted.flatMap { name, node -> [TreeNode] in
            let id = path.isEmpty ? name : path + "/" + name
            let row = TreeNode(id: id, name: name, depth: depth, isFolder: node.fileIndex == nil,
                               size: node.size, indices: node.indices)
            guard row.isFolder, !collapsed.contains(id) else { return [row] }
            return [row] + node.rows(path: id, depth: depth + 1, collapsed: collapsed)
        }
    }
}

struct NewTorrentSheet: View {
    @ObservedObject var pending: PendingTorrent
    @ObservedObject var manager: TorrentManager
    @AppStorage("folder") private var folder = NSHomeDirectory() + "/Downloads"
    @AppStorage("seed") private var seed = false
    @State private var selected: Set<Int> = []
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Новая загрузка").font(.title2.bold())

            if let info = pending.info {
                // что качаем и куда — одна группа, файлы — другая
                VStack(alignment: .leading, spacing: 6) {
                    Text(info.name).font(.headline).lineLimit(2).truncationMode(.middle)
                    folderRow
                }
                files(info)
                HStack {
                    Toggle("Раздавать после загрузки", isOn: $seed)
                        .toggleStyle(.brandCheckbox)
                        .help("DownMax будет раздавать файлы, пока вы не нажмёте ■ в строке. Без галочки раздачи нет, её можно включить позже.")
                    Spacer()
                    Text(summary(info)).font(.callout).foregroundStyle(.secondary)
                }
            } else if let error = pending.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Получаю список файлов от участников раздачи…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Отмена", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Скачать") {
                    guard let info = pending.info else { return }
                    manager.add(info, selected: selected, folder: folder, seed: seed)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.brandFill)
                .disabled(pending.info == nil || selected.isEmpty)
            }
            .controlSize(.large)
            .padding(.top, 8)  // 24 от содержимого: кнопки — отдельная группа
        }
        .padding(24)
        .buttonStyle(.gray)
        .frame(width: 620)
        .onChange(of: pending.info?.torrent) { _, _ in
            selected = Set(pending.info?.files.map(\.index) ?? [])
        }
        .onAppear { selected = Set(pending.info?.files.map(\.index) ?? []) }
    }

    private var folderRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(folder)
                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            Button("Изменить…", action: chooseFolder).buttonStyle(.brandLink).padding(.leading, 2)
            Spacer()
        }
    }

    private func files(_ info: TorrentInfo) -> some View {
        let nodes = TreeBuilder(info.files).rows(collapsed: collapsed)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Файлы: \(info.files.count)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Выбрать все") { selected = Set(info.files.map(\.index)) }.buttonStyle(.brandLink)
                Button("Снять выделение") { selected = [] }.buttonStyle(.brandLink)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(nodes) { row($0) }
                }
                .padding(.vertical, 6)
            }
            .frame(height: min(CGFloat(nodes.count) * 26 + 12, 300))
            .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Color.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Color.hairline))
        }
    }

    private func row(_ node: TreeNode) -> some View {
        let isFolder = node.isFolder
        let chosen = node.indices.filter(selected.contains).count
        let mark = chosen == 0 ? "square" : (chosen == node.indices.count ? "checkmark.square.fill" : "minus.square.fill")
        return HStack(spacing: 6) {
            Group {
                if isFolder {
                    Button {
                        if collapsed.contains(node.id) { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
                    } label: {
                        Image(systemName: collapsed.contains(node.id) ? "chevron.right" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(collapsed.contains(node.id) ? "Развернуть" : "Свернуть")
                } else {
                    Color.clear.frame(width: 14)
                }
            }
            Button {
                if chosen == node.indices.count { selected.subtract(node.indices) } else { selected.formUnion(node.indices) }
            } label: {
                Image(systemName: mark).foregroundStyle(chosen == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.brand))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(node.name)
            .accessibilityValue(chosen == 0 ? "не выбрано" : (chosen == node.indices.count ? "выбрано" : "выбрано частично"))
            Image(systemName: isFolder ? "folder.fill" : "doc").foregroundStyle(.secondary).frame(width: 18)
            Text(node.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            Text(bytes(Double(node.size))).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.callout)
        .padding(.leading, CGFloat(node.depth) * 18 + 10)
        .padding(.trailing, 14)
        .frame(height: 26)
    }

    private func summary(_ info: TorrentInfo) -> String {
        let size = info.files.filter { selected.contains($0.index) }.reduce(Int64(0)) { $0 + $1.size }
        let free = (try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        return "Размер: \(bytes(Double(size)))" + (free.map { " · свободно \(bytes(Double($0)))" } ?? "")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let u = panel.url { folder = u.path }
    }

    private func close() {
        pending.cancel()
        manager.pending = nil
    }
}

// MARK: - Строка торрента в списке

struct TorrentRow: View {
    @ObservedObject var job: TorrentJob
    let manager: TorrentManager
    @Binding var checked: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $checked).toggleStyle(.brandCheckbox).labelsHidden()
            icon.font(.title2).frame(width: 28)

            // между заголовком, полосой и состоянием — 8: видно ~10 до плашки метки и ~11 до полосы, больше
            // межстрочного воздуха заголовка (~7) — не влипает
            VStack(alignment: .leading, spacing: 8) {
                Text(job.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if job.state == .downloading || job.state == .paused || job.state == .queued {
                    // ищет участников (скорость 0) — по полосе бежит блик, как только пошло — обычная
                    LoadBar(value: job.progress, waiting: job.state == .downloading && job.downSpeed == 0,
                            dimmed: job.state != .downloading)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    SourceTag(name: job.sourceName)
                    Text(job.state == .done && !job.filesDeleted
                         ? ([job.detail, job.doneDate.map(DoneDate.text)].compactMap { $0 }.joined(separator: " · "))
                         : job.detail)
                        .font(.subheadline)  // 11: не мельче метки источника
                        .foregroundStyle(job.state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 0) {
                switch job.state {
                case .downloading:
                    iconButton("pause", "Пауза", job.pause)
                    iconButton("xmark", "Отменить загрузку…") { manager.cancel(job) }
                case .paused:
                    iconButton("play", "Продолжить") { job.start() }
                    iconButton("xmark", "Отменить загрузку…") { manager.cancel(job) }
                case .queued:
                    iconButton("play", "Начать сейчас, не дожидаясь очереди") { job.start() }
                    iconButton("xmark", "Отменить загрузку…") { manager.cancel(job) }
                case .seeding:
                    iconButton("folder", "Показать в Finder", reveal)
                    iconButton("stop.fill", "Остановить раздачу", job.stopSeeding)
                case .done:
                    if job.canSeed { iconButton("arrow.up", "Раздавать", job.startSeeding) }
                    if hasFiles {
                        if job.isFile { iconButton("play", "Открыть", open) }
                        iconButton("folder", "Показать в Finder", reveal)
                        iconButton("trash", "Удалить файлы с диска…", trash)
                    }
                    iconButton("xmark", "Удалить загрузку…") { BulkDelete.run([.torrent(job)]) }
                case .failed:
                    iconButton("arrow.clockwise", "Повторить") { job.start() }
                    iconButton("xmark", "Отменить загрузку…") { manager.cancel(job) }
                }
            }
            .padding(.trailing, -6)  // значок, а не поле 28, — на 14 от края, как галочка слева
        }
        .padding(Metrics.cardPadding)
        .rowCard()
        .contextMenu {
            if job.state == .downloading { Button("Пауза", action: job.pause) }
            if job.state == .paused || job.state == .failed { Button("Продолжить") { job.start() } }
            if job.state == .queued { Button("Начать сейчас") { job.start() } }
            if job.state == .seeding { Button("Остановить раздачу", action: job.stopSeeding) }
            if job.canSeed { Button("Раздавать", action: job.startSeeding) }
            if job.isFile && hasFiles && job.state == .done { Button("Открыть", action: open) }
            if hasFiles || job.state != .done { Button("Показать в Finder", action: reveal) }
            Divider()
            if job.state == .done {
                if hasFiles { Button("Удалить файлы с диска…", action: trash) }
                Button("Удалить загрузку…") { BulkDelete.run([.torrent(job)]) }
            } else if job.state != .seeding {
                Button("Отменить загрузку…") { manager.cancel(job) }
            }
        }
    }

    private var hasFiles: Bool { !job.filesDeleted && FileManager.default.fileExists(atPath: job.target) }

    private func open() { NSWorkspace.shared.open(URL(fileURLWithPath: job.target)) }

    private func reveal() {
        let url = URL(fileURLWithPath: job.target)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: job.record.folder))
        }
    }

    private func trash() {
        let url = URL(fileURLWithPath: job.target)
        guard Ask.run("Удалить файлы с диска?", "«\(url.lastPathComponent)» будет перемещён в Корзину.",
                      buttons: ["В Корзину", "Отмена"]) == 0 else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            job.filesDeleted = true
            job.detail = "Файлы перемещены в Корзину"
        } catch {
            job.detail = "Не удалось удалить: \(error.localizedDescription)"
        }
    }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .downloading: Image(systemName: job.isFile ? "arrow.down.doc" : "arrow.down.circle").foregroundStyle(Color.brand)
        case .paused: Image(systemName: "pause.circle").foregroundStyle(.secondary)
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .seeding: Image(systemName: "arrow.up.circle").foregroundStyle(.green)
        // файлов на диске нет — галочка серая: загрузка была, но «всё готово» уже неправда
        case .done: Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(job.filesDeleted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.green))
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        IconButton(symbol, help, action: action)
    }
}

// MARK: - DownMax как приложение для торрентов по умолчанию

enum TorrentHandler {
    static var torrentType: UTType { UTType("org.bittorrent.torrent") ?? UTType(filenameExtension: "torrent") ?? .data }

    /// Кто сейчас открывает magnet-ссылки: имя приложения или nil.
    static var magnetApp: URL? { NSWorkspace.shared.urlForApplication(toOpen: URL(string: "magnet:?xt=urn:btih:0")!) }
    /// Кто открывает файлы .torrent.
    static var fileApp: URL? { NSWorkspace.shared.urlForApplication(toOpen: torrentType) }
    /// По умолчанию — только если DownMax открывает и magnet-ссылки, и файлы .torrent.
    static var isDefault: Bool {
        let me = Bundle.main.bundleURL.standardizedFileURL.path
        return magnetApp?.standardizedFileURL.path == me && fileApp?.standardizedFileURL.path == me
    }

    /// При первом запуске DownMax сам становится приложением для торрентов (решение пользователя) — один раз:
    /// если потом выберут другое приложение, не спорим, в «Компонентах» остаётся кнопка «Открывать в DownMax».
    static func claimOnce() {
        let key = "torrentHandlerClaimed"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !isDefault { makeDefault {} }
    }

    /// macOS сама спрашивает пользователя, менять ли приложение по умолчанию.
    static func makeDefault(_ done: @escaping () -> Void) {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "magnet") { _ in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: torrentType) { _ in
                DispatchQueue.main.async(execute: done)
            }
        }
    }
}

/// Строка в «Компонентах»: чем открываются magnet-ссылки и .torrent.
struct TorrentHandlerRow: View {
    @State private var current: URL? = TorrentHandler.magnetApp
    @State private var isDefault = TorrentHandler.isDefault
    @State private var fromBrowser = TorrentWatcher.enabled
    @State private var skipSelection = TorrentManager.skipSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().padding(.horizontal, -14)  // во всю ширину карточки, как в списке программ
            option("Открывать скачанные сразу", "DownMax сам откроет торрент, который браузер скачал в «Загрузки»",
                   isOn: $fromBrowser)
                .onChange(of: fromBrowser) { _, value in TorrentWatcher.enabled = value }
            option("Качать без выбора файлов", "Торрент сразу качается целиком в папку для загрузок",
                   isOn: $skipSelection)
                .onChange(of: skipSelection) { _, value in TorrentManager.skipSelection = value }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Color.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Color.hairline))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    /// Настройка торрентов: подпись в колонке текста карточки (под заголовком), переключатель справа.
    private func option(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.leading, 32)  // 22 значок + 10 — ровно под заголовком «Торренты»
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(.brand)
                .labelsHidden()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isDefault ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(isDefault ? .green : .orange)
                .font(.title3)
                .frame(width: 22)  // одна колонка значков во всех карточках «Компонентов»
            VStack(alignment: .leading, spacing: 2) {
                Text("Торренты").font(.headline)
                Text("magnet-ссылки из браузера и файлы .torrent")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            if !isDefault {
                Button("Открывать в DownMax") { TorrentHandler.makeDefault(refresh) }
            }
        }
    }

    private var status: String {
        if isDefault { return "открываются в DownMax" }
        guard let app = current else { return "нечем открыть" }
        return "открываются в " + FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    private func refresh() {
        current = TorrentHandler.magnetApp
        isDefault = TorrentHandler.isDefault
    }
}

// MARK: - Файл или страница с видео

/// Ссылку из поля ввода сначала проверяем: страница или видео — в yt-dlp, файл (zip, dmg, pdf…) — в aria2c.
/// Сам файл не качается: запрос прерывается, как только пришли заголовки ответа.
enum FileLink {
    struct Info {
        let url: String      // исходный адрес: конечный после переадресаций бывает временным (GitHub)
        let name: String
        let size: Int64?
    }

    enum Kind { case video, file(Info) }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Сайты, где по ссылке всегда страница с видео, — без лишнего запроса.
    private static let videoHosts = ["youtube.com", "youtu.be", "vk.com", "vk.ru", "vkvideo.ru", "instagram.com",
                                     "threads.com", "threads.net", "vimeo.com", "getcourse.ru", "rutube.ru",
                                     "tiktok.com", "twitter.com", "x.com", "twitch.tv", "dzen.ru", "ok.ru"]

    static func detect(_ link: String) async -> Kind {
        guard let url = URL(string: link), let host = url.host?.lowercased() else { return .video }
        if videoHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return .video }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")  // вдруг сервер всё же начнёт отдавать тело
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (stream, response) = try? await URLSession.shared.bytes(for: request),
              let http = response as? HTTPURLResponse else { return .video }
        stream.task.cancel()
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let disposition = http.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let isPage = type.hasPrefix("text/html") || type.contains("xhtml")
        let isMedia = type.hasPrefix("video/") || type.hasPrefix("audio/") || type.contains("mpegurl") || type.contains("dash+xml")
        guard (200..<300).contains(http.statusCode), !isPage, !isMedia || disposition.lowercased().hasPrefix("attachment") else {
            return .video
        }
        return .file(Info(url: link, name: name(disposition: disposition, url: http.url ?? url), size: size(http)))
    }

    /// Имя из Content-Disposition (filename* в UTF-8 важнее filename), иначе — из адреса.
    private static func name(disposition: String, url: URL) -> String {
        var found: String?
        for part in disposition.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let lower = part.lowercased()
            if lower.hasPrefix("filename*=") {
                let value = part.dropFirst("filename*=".count)
                let encoded = value.components(separatedBy: "''").last ?? String(value)
                if let decoded = encoded.removingPercentEncoding { found = decoded; break }
            } else if lower.hasPrefix("filename="), found == nil {
                found = part.dropFirst("filename=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        let fromURL = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let raw = found ?? (fromURL.isEmpty || fromURL == "/" ? "download" : fromURL)
        let clean = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return clean.isEmpty ? "download" : clean
    }

    /// Размер: из Content-Range (ответ на Range) или Content-Length.
    private static func size(_ http: HTTPURLResponse) -> Int64? {
        if let range = http.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last {
            return Int64(total)
        }
        return http.expectedContentLength > 1 ? http.expectedContentLength : nil
    }
}

// MARK: - Торрент, скачанный браузером

/// Браузер скачивает .torrent в «Загрузки» и сам его не открывает. DownMax следит за папкой и открывает новый
/// торрент сразу — окно выбора файлов, как при двойном щелчке. Старые файлы не трогает: только появившиеся после запуска.
enum TorrentWatcher {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "torrentFromBrowser") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "torrentFromBrowser")
            newValue ? start() : stop()
        }
    }

    private static let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
    private static var source: DispatchSourceFileSystemObject?
    private static var known = Set<String>()

    static func start() {
        guard enabled, source == nil else { return }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        known = Set(torrents())
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { scan() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    static func stop() {
        source?.cancel()
        source = nil
    }

    private static func torrents() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".torrent") }
    }

    /// Браузеры пишут во временный файл (.crdownload, .download) и переименовывают в конце — появился .torrent,
    /// значит скачан целиком. Секунда паузы — на случай браузера, который пишет прямо в итоговый файл.
    private static func scan() {
        let fresh = torrents().filter { !known.contains($0) }
        guard !fresh.isEmpty else { return }
        known.formUnion(fresh)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            for name in fresh {
                let url = folder.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                Inbox.shared.note("торрент из «Загрузок»: \(name)")
                TorrentManager.shared.open(torrentFile: url, fromBrowser: true)
                NSApp.activate()  // окно выбора файлов — на экран
            }
        }
    }
}
