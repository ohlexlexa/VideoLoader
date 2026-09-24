import SwiftUI
import AppKit

// MARK: - Настройки загрузки

enum Mode: String, CaseIterable, Identifiable {
    case video = "Видео"
    case audioM4A = "Звук m4a"
    case audioMP3 = "Звук mp3"
    var id: String { rawValue }
}

enum Quality: Int, CaseIterable, Identifiable {
    case best = 0, p2160 = 2160, p1440 = 1440, p1080 = 1080, p720 = 720, p480 = 480
    var id: Int { rawValue }
    var title: String { self == .best ? "Максимальное" : "\(rawValue)p" }
}

enum Tools {
    static let searchPath = [
        "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
        NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.deno/bin",
        "/usr/bin", "/bin",
    ]

    static func find(_ name: String) -> String? {
        searchPath.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPath + [env["PATH"] ?? ""]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["HOMEBREW_NO_ASK"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        return env
    }

    /// Запускает программу и возвращает первую строку вывода (для версий).
    static func firstLine(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline).first.map(String.init)
    }
}

// MARK: - Расширение для браузеров (Chrome, Яндекс Браузер)

/// Браузер на движке Chromium, куда можно загрузить распакованное расширение.
enum Browser: String, CaseIterable, Identifiable {
    case chrome, yandex
    var id: String { rawValue }

    var name: String {
        switch self {
        case .chrome: "Google Chrome"
        case .yandex: "Яндекс Браузер"
        }
    }

    /// Название в предложном падеже: «в Яндекс Браузере».
    var nameIn: String {
        switch self {
        case .chrome: "Google Chrome"
        case .yandex: "Яндекс Браузере"
        }
    }

    var appPath: String {
        switch self {
        case .chrome: "/Applications/Google Chrome.app"
        case .yandex: "/Applications/Yandex.app"
        }
    }

    var extensionsPage: String {
        switch self {
        case .chrome: "chrome://extensions"
        case .yandex: "browser://extensions"
        }
    }

    var profilesDir: String {
        switch self {
        case .chrome: NSHomeDirectory() + "/Library/Application Support/Google/Chrome"
        case .yandex: NSHomeDirectory() + "/Library/Application Support/Yandex/YandexBrowser"
        }
    }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: appPath) }

    /// Путь распакованного расширения браузер хранит в настройках профиля.
    var hasExtension: Bool {
        guard let profiles = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: profilesDir), includingPropertiesForKeys: nil) else { return false }
        let path = BrowserExtension.folder.path
        let needles = [path, path.replacingOccurrences(of: "/", with: "\\/")].map { Data($0.utf8) }
        for profile in profiles {
            for name in ["Secure Preferences", "Preferences"] {
                guard let data = try? Data(contentsOf: profile.appendingPathComponent(name)) else { continue }
                if needles.contains(where: { data.range(of: $0) != nil }) { return true }
            }
        }
        return false
    }
}

struct BrowserState: Identifiable {
    let browser: Browser
    var extensionInstalled: Bool
    var id: String { browser.id }
}

/// Расширение лежит внутри приложения (Resources/chrome-extension). Браузер грузит распакованное
/// расширение из папки и помнит её путь, поэтому оно копируется в постоянное место вне приложения.
enum BrowserExtension {
    static let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/VideoLoader/chrome-extension")
    static var bundled: URL? { Bundle.main.url(forResource: "chrome-extension", withExtension: nil) }

    @discardableResult
    static func sync() -> Bool {
        guard let source = bundled else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: folder)
        return (try? fm.copyItem(at: source, to: folder)) != nil
    }

    /// Обновляет уже распакованное расширение до версии из приложения.
    static func refreshIfInstalled() {
        if FileManager.default.fileExists(atPath: folder.path) { sync() }
    }
}

// MARK: - Компоненты: yt-dlp, ffmpeg, deno

struct Component: Identifiable {
    let id: String
    let purpose: String
    let versionArgs: [String]
    let parseVersion: (String) -> String
    var path: String?
    var version: String?
    var installed: Bool { path != nil }
}

final class Setup: ObservableObject {
    static let shared = Setup()
    @Published var components: [Component] = [
        Component(id: "yt-dlp", purpose: "скачивает видео с YouTube", versionArgs: ["--version"],
                  parseVersion: { $0 }),
        Component(id: "ffmpeg", purpose: "склеивает видео со звуком, делает mp3", versionArgs: ["-version"],
                  parseVersion: { $0.split(separator: " ").dropFirst(2).first.map(String.init) ?? $0 }),
        Component(id: "deno", purpose: "нужен yt-dlp, чтобы проходить защиту YouTube", versionArgs: ["--version"],
                  parseVersion: { $0.split(separator: " ").dropFirst().first.map(String.init) ?? $0 }),
    ]
    @Published var brewPath: String?
    @Published var checked = false
    @Published var busy: String?
    @Published var log = ""
    @Published var failed = false
    @Published var showSheet = false
    @Published var waitingForTerminal = false
    @Published var browsers: [BrowserState] = []
    @Published var extensionHelpFor: Browser?

    var extensionMissing: Bool { !browsers.isEmpty && !browsers.contains(where: \.extensionInstalled) }

    var missing: [Component] { components.filter { !$0.installed } }
    var allGood: Bool { checked && missing.isEmpty }
    var canDownload: Bool { checked && components.prefix(2).allSatisfy(\.installed) }

    var installCommand: String { "brew install " + missing.map(\.id).joined(separator: " ") }

    func refresh(openIfMissing: Bool = false) {
        let current = components
        DispatchQueue.global(qos: .userInitiated).async {
            var updated = current
            for i in updated.indices {
                let path = Tools.find(updated[i].id)
                updated[i].path = path
                updated[i].version = path
                    .flatMap { Tools.firstLine($0, updated[i].versionArgs) }
                    .map(updated[i].parseVersion)
            }
            let brew = Tools.find("brew")
            let browsers = Browser.allCases.filter(\.isInstalled)
                .map { BrowserState(browser: $0, extensionInstalled: $0.hasExtension) }
            DispatchQueue.main.async {
                self.components = updated
                self.brewPath = brew
                self.browsers = browsers
                if let b = self.extensionHelpFor, browsers.first(where: { $0.browser == b })?.extensionInstalled == true {
                    self.extensionHelpFor = nil
                }
                self.checked = true
                if self.waitingForTerminal && self.missing.isEmpty { self.waitingForTerminal = false }
                if openIfMissing && !self.missing.isEmpty { self.showSheet = true }
            }
        }
    }

    func installExtension(in browser: Browser) {
        guard BrowserExtension.sync() else {
            failed = true
            log = "Не удалось распаковать расширение в \(BrowserExtension.folder.path)"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(BrowserExtension.folder.path, forType: .string)
        NSWorkspace.shared.activateFileViewerSelecting([BrowserExtension.folder])
        if let page = URL(string: browser.extensionsPage) {
            NSWorkspace.shared.open([page], withApplicationAt: URL(fileURLWithPath: browser.appPath),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
        extensionHelpFor = browser
    }

    func installMissing() {
        guard !missing.isEmpty else { return }
        if brewPath != nil {
            runBrew(["install"] + missing.map(\.id), title: "Устанавливаю " + missing.map(\.id).joined(separator: ", "))
        } else {
            openTerminalInstaller()
        }
    }

    func updateYtdlp() {
        runBrew(["upgrade", "yt-dlp"], title: "Обновляю yt-dlp")
    }

    private func runBrew(_ args: [String], title: String) {
        guard let brew = brewPath, busy == nil else { return }
        busy = title
        failed = false
        log = "$ brew " + args.joined(separator: " ") + "\n"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: brew)
        p.arguments = args
        p.environment = Tools.environment
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let group = DispatchGroup()
        group.enter()
        let splitter = LineSplitter { line in DispatchQueue.main.async { self.appendLog(line) } }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                splitter.flush()
                group.leave()
            } else {
                splitter.append(data)
            }
        }
        group.enter()
        p.terminationHandler = { _ in group.leave() }
        group.notify(queue: .main) {
            self.busy = nil
            self.failed = p.terminationStatus != 0
            self.appendLog(self.failed ? "Ошибка: brew завершился с кодом \(p.terminationStatus)" : "Готово.")
            self.refresh()
        }

        do { try p.run() } catch {
            busy = nil
            failed = true
            appendLog("Не удалось запустить brew: \(error.localizedDescription)")
        }
    }

    private func appendLog(_ line: String) {
        var lines = (log + line + "\n").split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
        log = lines.joined(separator: "\n")
    }

    /// Homebrew ставится только с паролем администратора, поэтому его установка идёт в Терминале.
    private func openTerminalInstaller() {
        let tools = missing.map(\.id).joined(separator: " ")
        let script = """
        #!/bin/bash
        clear
        echo "Установка компонентов для «Загрузка видео»"
        echo "Сначала Homebrew — он попросит пароль администратора Mac (символы при вводе не видны)."
        echo
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || { echo; echo "Homebrew не установился. Окно можно закрыть."; exit 1; }
        if [ -x /opt/homebrew/bin/brew ]; then BREW=/opt/homebrew/bin/brew; else BREW=/usr/local/bin/brew; fi
        eval "$($BREW shellenv)"
        grep -q "brew shellenv" ~/.zprofile 2>/dev/null || echo "eval \\"\\$($BREW shellenv)\\"" >> ~/.zprofile
        echo
        echo "Ставлю: \(tools)"
        HOMEBREW_NO_ASK=1 brew install \(tools)
        echo
        echo "Готово. Вернитесь в «Загрузка видео», это окно можно закрыть."
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("videoloader-setup.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
            waitingForTerminal = true
            failed = false
            log = ""
        } catch {
            failed = true
            log = "Не удалось подготовить установку: \(error.localizedDescription)"
        }
    }
}

/// title — имя файла, когда у источника своего названия нет (поток GetCourse приходит без него).
func buildArguments(mode: Mode, maxHeight: Int?, compatible: Bool, folder: String, url: String,
                    title: String? = nil) -> [String] {
    // В шаблонах yt-dlp «%» — служебный символ, в готовом названии его надо удвоить.
    let fixedTitle = title.map { sanitizeFilename($0).replacingOccurrences(of: "%", with: "%%") }
    var args = [
        "--no-playlist", "--newline", "--progress", "--no-simulate",
        "--print", "before_dl:TITLE " + (fixedTitle ?? "%(title)s"),
        "--print", "after_move:FILE %(filepath)s",
        "--progress-template",
        "download:PROG %(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
        "-P", folder,
        "-o", (fixedTitle ?? "%(title)s") + ".%(ext)s",
    ]
    switch mode {
    case .video:
        let cap = maxHeight.map { ":\($0)" } ?? ""
        let sort = compatible ? "vcodec:h264,res\(cap),acodec:aac" : "res\(cap)"
        args += ["-f", "bv*+ba/b", "-S", sort, "--merge-output-format", "mp4"]
    case .audioM4A:
        args += ["-f", "ba[ext=m4a]/ba", "-x", "--audio-format", "m4a"]
    case .audioMP3:
        args += ["-f", "ba", "-x", "--audio-format", "mp3", "--audio-quality", "0"]
    }
    args += ["--", url]
    return args
}

/// Ссылки на vimeo.com yt-dlp без входа в аккаунт больше не открывает, а ссылки встроенного
/// плеера — открывает. vimeo.com/<id>, vimeo.com/<id>/<ключ скрытого видео>, …/channels/…/<id>
/// превращаются в player.vimeo.com/video/<id>?h=<ключ>.
func vimeoPlayerURL(_ raw: String) -> String? {
    guard let u = URLComponents(string: raw), let host = u.host?.lowercased(),
          host == "vimeo.com" || host.hasSuffix(".vimeo.com"), host != "player.vimeo.com" else { return nil }
    let parts = u.path.split(separator: "/").map(String.init)
    guard let i = parts.lastIndex(where: { $0.count >= 6 && $0.allSatisfy(\.isNumber) }) else { return nil }
    let key = i + 1 < parts.count && parts[i + 1].allSatisfy(\.isHexDigit) ? parts[i + 1]
        : u.queryItems?.first(where: { $0.name == "h" })?.value
    return "https://player.vimeo.com/video/\(parts[i])" + (key.map { "?h=\($0)" } ?? "")
}

func sanitizeFilename(_ s: String) -> String {
    // Двоеточие и слэш в имени файла недопустимы — заменяем похожими символами, как это делает yt-dlp.
    let replaced = s.replacingOccurrences(of: ":", with: "：").replacingOccurrences(of: "/", with: "⧸")
    let banned = CharacterSet(charactersIn: "\\").union(.controlCharacters).union(.newlines)
    let cleaned = replaced.components(separatedBy: banned).joined(separator: " ")
        .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    return cleaned.isEmpty ? "video" : String(cleaned.prefix(150))
}

/// Недокачанные куски (.part, .ytdl, Frag…) живут здесь, в «Загрузки» попадает только готовый файл.
/// У каждой загрузки своя подпапка; она удаляется, чем бы загрузка ни закончилась.
enum TempFiles {
    static let folder = NSHomeDirectory() + "/Library/Caches/VideoLoader"

    static func folder(for id: UUID) -> String { folder + "/" + id.uuidString }

    static func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// При запуске загрузок ещё нет — всё, что лежит, осталось после сбоя или выхода.
    static func removeAll() { remove(folder) }
}

/// Все запущенные yt-dlp: при выходе из приложения их надо остановить,
/// иначе они докачивают в фоне без окна и оставляют куски.
enum RunningProcesses {
    private static var list: [Process] = []
    private static let lock = NSLock()

    static func add(_ p: Process) { lock.lock(); list.append(p); lock.unlock() }
    static func remove(_ p: Process) { lock.lock(); list.removeAll { $0 === p }; lock.unlock() }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return list.count }

    static func stopAll() {
        lock.lock(); let all = list; lock.unlock()
        all.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while all.contains(where: \.isRunning) && Date() < deadline { usleep(50_000) }
    }
}

// MARK: - Разбор вывода по строкам

final class LineSplitter {
    private var buffer = Data()
    private let onLine: (String) -> Void
    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func append(_ data: Data) {
        buffer.append(data)
        while let i = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<i]
            buffer.removeSubrange(buffer.startIndex...i)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty { onLine(line) }
        }
    }

    func flush() {
        if let line = String(data: buffer, encoding: .utf8), !line.isEmpty { onLine(line) }
        buffer.removeAll()
    }
}

// MARK: - Одна загрузка

final class DownloadJob: ObservableObject, Identifiable {
    enum State { case starting, downloading, processing, done, failed, cancelled }

    let id = UUID()
    let url: String
    let arguments: [String]
    @Published var title: String
    @Published var state: State = .starting
    @Published var progress: Double = 0
    @Published var detail = "Получаю сведения о видео…"
    @Published var filePath: String?
    @Published var fileDeleted = false

    private var process: Process?
    private var lastError: String?
    private var cancelled = false

    /// Набор файлов по прямым ссылкам (карусель Instagram): качается без yt-dlp.
    let gallery: [GalleryItem]?
    private let galleryTarget: String?
    private var task: Task<Void, Never>?

    var isRunning: Bool { [.starting, .downloading, .processing].contains(state) }

    init(url: String, arguments: [String]) {
        self.url = url
        self.arguments = arguments
        self.title = url
        self.gallery = nil
        self.galleryTarget = nil
    }

    init(gallery: [GalleryItem], target: String, title: String, arguments: [String]) {
        self.url = "gallery"
        self.arguments = arguments
        self.title = title
        self.gallery = gallery
        self.galleryTarget = target
    }

    /// Скачивает файлы по очереди во временную папку и только в конце переносит их
    /// в «Загрузки»: одним файлом, если он один, или папкой с 01.jpg, 02.mp4…
    func startGallery() {
        guard let items = gallery, let target = galleryTarget else { return }
        state = .downloading
        let temp = TempFiles.folder(for: id)
        task = Task { @MainActor in
            let fm = FileManager.default
            do {
                try fm.createDirectory(atPath: temp, withIntermediateDirectories: true)
                var files: [URL] = []
                for (i, item) in items.enumerated() {
                    try Task.checkCancellation()
                    detail = "Файл \(i + 1) из \(items.count)…"
                    progress = Double(i) / Double(items.count)
                    guard let source = URL(string: item.u) else { throw URLError(.badURL) }
                    let (downloaded, response) = try await URLSession.shared.download(from: source)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw NSError(domain: "VideoLoader", code: http.statusCode,
                                      userInfo: [NSLocalizedDescriptionKey: "сервер ответил \(http.statusCode) на файл \(i + 1)"])
                    }
                    let dest = URL(fileURLWithPath: temp).appendingPathComponent(String(format: "%02d.%@", i + 1, item.k))
                    try? fm.removeItem(at: dest)
                    try fm.moveItem(at: downloaded, to: dest)
                    files.append(dest)
                }
                let targetURL = URL(fileURLWithPath: target)
                if files.count == 1 {
                    try fm.moveItem(at: files[0], to: targetURL)
                } else {
                    try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
                    for f in files { try fm.moveItem(at: f, to: targetURL.appendingPathComponent(f.lastPathComponent)) }
                }
                TempFiles.remove(temp)
                filePath = target
                let videos = items.filter { $0.k == "mp4" }.count
                let photos = items.count - videos
                let parts = [photos > 0 ? "\(photos) фото" : nil, videos > 0 ? "\(videos) видео" : nil].compactMap { $0 }
                markDone(note: files.count > 1 ? parts.joined(separator: " и ") : nil)
            } catch {
                TempFiles.remove(temp)
                if cancelled || error is CancellationError {
                    state = .cancelled
                    detail = "Отменено"
                } else {
                    state = .failed
                    detail = "Не удалось скачать: \(error.localizedDescription)"
                }
            }
        }
    }

    func start(ytdlp: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ytdlp)
        var args = arguments
        if let i = args.firstIndex(of: "--") {
            args.insert(contentsOf: ["-P", "temp:" + TempFiles.folder(for: id)], at: i)
        }
        p.arguments = args
        p.environment = Tools.environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let group = DispatchGroup()
        for pipe in [out, err] {
            group.enter()
            let splitter = LineSplitter { line in DispatchQueue.main.async { self.handle(line) } }
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    splitter.flush()
                    group.leave()
                } else {
                    splitter.append(data)
                }
            }
        }
        group.enter()
        p.terminationHandler = { _ in group.leave() }
        group.notify(queue: .main) { self.finish(status: p.terminationStatus) }

        do {
            try p.run()
            process = p
            RunningProcesses.add(p)
        } catch {
            state = .failed
            detail = "Не удалось запустить yt-dlp: \(error.localizedDescription)"
        }
    }

    func cancel() {
        cancelled = true
        process?.terminate()
        task?.cancel()
    }

    private func handle(_ line: String) {
        if line.hasPrefix("TITLE ") {
            title = String(line.dropFirst(6))
        } else if line.hasPrefix("FILE ") {
            filePath = String(line.dropFirst(5))
        } else if line.hasPrefix("PROG ") {
            handleProgress(String(line.dropFirst(5)))
        } else if line.hasPrefix("ERROR:") {
            lastError = line.replacingOccurrences(of: "ERROR: ", with: "")
        }
    }

    private func handleProgress(_ s: String) {
        let f = s.split(separator: "|", omittingEmptySubsequences: false).map { Double($0) }
        guard f.count == 5, let done = f[0] else { return }
        let total = f[1] ?? f[2]
        if let total, total > 0 {
            progress = min(done / total, 1)
        }
        if progress >= 0.999 {
            state = .processing
            detail = "Обработка…"
            return
        }
        state = .downloading
        var parts: [String] = []
        if let total { parts.append("\(bytes(done)) из \(bytes(total))") } else { parts.append(bytes(done)) }
        if let speed = f[3] { parts.append("\(bytes(speed))/с") }
        if let eta = f[4] { parts.append("осталось \(duration(eta))") }
        detail = parts.joined(separator: " · ")
    }

    private func finish(status: Int32) {
        if let p = process { RunningProcesses.remove(p) }
        process = nil
        TempFiles.remove(TempFiles.folder(for: id))
        if cancelled {
            state = .cancelled
            detail = "Отменено"
        } else if status == 0 {
            if let path = filePath, needsQuickTimeConversion(path) {
                convertForQuickTime(path)
            } else {
                markDone()
            }
        } else {
            state = .failed
            detail = lastError ?? "yt-dlp завершился с ошибкой (код \(status))"
        }
    }

    private func markDone(note: String? = nil) {
        state = .done
        progress = 1
        let name = filePath.map { ($0 as NSString).lastPathComponent }
        detail = (["Готово", name, note].compactMap { $0 }).joined(separator: " · ")
    }

    // Instagram отдаёт лучшее качество только в VP9 — его не открывают ни QuickTime,
    // ни просмотр по пробелу. Такой файл перекодируется в H.264 аппаратным кодировщиком Mac.
    private func needsQuickTimeConversion(_ path: String) -> Bool {
        guard url.contains("instagram.com"), let ffprobe = Tools.find("ffprobe") else { return false }
        let codec = Tools.firstLine(ffprobe, ["-v", "error", "-select_streams", "v:0",
                                              "-show_entries", "stream=codec_name", "-of", "default=nw=1:nk=1", path])
        return ["vp9", "av1"].contains(codec ?? "")
    }

    private func convertForQuickTime(_ path: String) {
        guard let ffmpeg = Tools.find("ffmpeg") else { return markDone() }
        state = .processing
        detail = "Перекодирую в H.264, чтобы видео открывалось в QuickTime…"

        // H.264 сжимает хуже VP9 — битрейт берём вдвое выше исходного, в разумных пределах.
        let sourceRate = Tools.find("ffprobe").flatMap {
            Tools.firstLine($0, ["-v", "error", "-show_entries", "format=bit_rate", "-of", "default=nw=1:nk=1", path])
        }.flatMap { Int($0) } ?? 3_000_000
        let rate = min(max(sourceRate * 2, 3_000_000), 20_000_000)

        let folder = TempFiles.folder(for: id)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let output = folder + "/converted.mp4"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-y", "-v", "error", "-i", path,
                       "-c:v", "h264_videotoolbox", "-b:v", String(rate), "-tag:v", "avc1",
                       "-c:a", "copy", "-movflags", "+faststart", output]
        p.environment = Tools.environment
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            DispatchQueue.main.async {
                RunningProcesses.remove(proc)
                self.process = nil
                var note: String? = nil
                if self.cancelled {
                    note = "без перекодирования"
                } else if proc.terminationStatus == 0 {
                    do {
                        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                                  withItemAt: URL(fileURLWithPath: output))
                    } catch {
                        note = "не удалось заменить файл перекодированным"
                    }
                } else {
                    note = "перекодировать не вышло, осталось VP9"
                }
                TempFiles.remove(folder)
                self.markDone(note: note)
            }
        }
        do {
            try p.run()
            process = p
            RunningProcesses.add(p)
        } catch {
            TempFiles.remove(folder)
            markDone(note: "перекодировать не вышло, осталось VP9")
        }
    }

    private func bytes(_ v: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file)
    }

    private func duration(_ s: Double) -> String {
        let t = Int(s)
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) }
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Список загрузок

/// Загрузки живут на уровне приложения, а не окна: ссылка из браузера должна скачаться,
/// даже если окно ещё не создано (приложение запущено в фоне) или закрыто.
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()
    @Published var jobs: [DownloadJob] = []
    @Published var alert: String?

    /// Параметры, которых нет в запросе, берутся из настроек окна (UserDefaults, как у @AppStorage).
    func download(url rawURL: String, mode: Mode? = nil, maxHeight: Int? = nil, title: String? = nil) {
        let url = vimeoPlayerURL(rawURL) ?? rawURL
        let d = UserDefaults.standard
        let savedMode = Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .video
        let savedQuality = Quality(rawValue: d.integer(forKey: "quality")) ?? .best
        let folder = d.string(forKey: "folder") ?? NSHomeDirectory() + "/Downloads"
        add(url: url, arguments: buildArguments(
            mode: mode ?? savedMode,
            maxHeight: maxHeight ?? (savedQuality == .best ? nil : savedQuality.rawValue),
            compatible: d.bool(forKey: "compatible"), folder: folder, url: url, title: title))
    }

    func add(url: String, arguments: [String]) {
        guard let ytdlp = Tools.find("yt-dlp") else {
            alert = "Не найден yt-dlp. Установите его через «Компоненты» внизу окна."
            return
        }
        // Две одновременные загрузки одного ролика пишут в одни и те же файлы и портят результат.
        guard !jobs.contains(where: { $0.isRunning && $0.arguments == arguments }) else { return }
        let job = DownloadJob(url: url, arguments: arguments)
        jobs.insert(job, at: 0)
        job.start(ytdlp: ytdlp)
        DockProgress.shared.start()
    }

    func downloadGallery(title: String, items: [GalleryItem]) {
        guard !items.isEmpty else { return }
        let base = UserDefaults.standard.string(forKey: "folder") ?? NSHomeDirectory() + "/Downloads"
        let name = sanitizeFilename(title)
        let arguments = ["gallery", name] + items.map(\.u)
        guard !jobs.contains(where: { $0.isRunning && $0.arguments == arguments }) else { return }
        let target = items.count == 1
            ? uniquePath(base + "/" + name, ext: items[0].k)
            : uniquePath(base + "/" + name, ext: nil)
        let job = DownloadJob(gallery: items, target: target, title: name, arguments: arguments)
        jobs.insert(job, at: 0)
        job.startGallery()
        DockProgress.shared.start()
    }

    /// «Имя.jpg», а если такое уже есть — «Имя (2).jpg»; для папок так же без расширения.
    private func uniquePath(_ base: String, ext: String?) -> String {
        let full = { (suffix: String) in base + suffix + (ext.map { "." + $0 } ?? "") }
        var n = 1
        var path = full("")
        while FileManager.default.fileExists(atPath: path) {
            n += 1
            path = full(" (\(n))")
        }
        return path
    }

    func retry(_ job: DownloadJob) {
        if let items = job.gallery {
            remove(job)
            downloadGallery(title: job.title, items: items)
            return
        }
        remove(job)
        add(url: job.url, arguments: job.arguments)
    }

    func remove(_ job: DownloadJob) {
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isRunning }
    }
}

/// Элемент карусели: прямая ссылка и расширение файла (jpg, mp4…).
struct GalleryItem: Codable, Equatable {
    let u: String
    let k: String
}

// MARK: - Ссылки videoloader:// от расширения Chrome

struct IncomingRequest {
    let url: String
    let mode: Mode?
    let maxHeight: Int?
    let title: String?
    var gallery: [GalleryItem]? = nil
}

final class Inbox: ObservableObject {
    static let shared = Inbox()
    /// Ссылка, которую уже получали недавно: приложение спрашивает, качать ли её снова.
    @Published var repeated: IncomingRequest?

    private static let recentKey = "recentLinks"
    private static let recentWindow: TimeInterval = 10 * 60
    private static let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/VideoLoader.log")

    /// videoloader://download?url=<ссылка>&mode=video|m4a|mp3&quality=<высота, например 1080>&title=<имя файла>
    func receive(_ link: URL, from sender: String) {
        // videoloader://gallery?title=<имя>&items=<JSON [{u, k}]> — карусель из окошка расширения
        if link.scheme == "videoloader", link.host == "gallery",
           let q = URLComponents(string: link.absoluteString.replacingOccurrences(of: "+", with: "%20"))?.queryItems,
           let json = q.first(where: { $0.name == "items" })?.value,
           let items = try? JSONDecoder().decode([GalleryItem].self, from: Data(json.utf8)), !items.isEmpty {
            let title = q.first(where: { $0.name == "title" })?.value ?? "Карусель"
            return accept(IncomingRequest(url: "gallery", mode: nil, maxHeight: nil, title: title, gallery: items),
                          link: link, sender: sender)
        }
        guard link.scheme == "videoloader",
              // «+» в параметрах — это пробел (так кодирует URLSearchParams в окошке расширения).
              let items = URLComponents(string: link.absoluteString.replacingOccurrences(of: "+", with: "%20"))?.queryItems,
              let target = items.first(where: { $0.name == "url" })?.value,
              let t = URL(string: target), ["http", "https"].contains(t.scheme ?? "")
        else {
            log("отклонена", link, sender)
            return
        }
        let mode: Mode? = switch items.first(where: { $0.name == "mode" })?.value {
        case "video": .video
        case "m4a": .audioM4A
        case "mp3": .audioMP3
        default: nil
        }
        let height = items.first(where: { $0.name == "quality" })?.value.flatMap { Int($0) }
        let title = items.first(where: { $0.name == "title" })?.value.flatMap { $0.isEmpty ? nil : $0 }
        let request = IncomingRequest(url: target, mode: mode, maxHeight: height, title: title)
        accept(request, link: link, sender: sender)
    }

    private func accept(_ request: IncomingRequest, link: URL, sender: String) {
        // Недавние ссылки хранятся между запусками: повтор может прийти и после перезапуска.
        let now = Date().timeIntervalSince1970
        var recent = (UserDefaults.standard.dictionary(forKey: Self.recentKey) as? [String: Double] ?? [:])
            .filter { now - $0.value < Self.recentWindow }
        let key = link.absoluteString
        if let seen = recent[key] {
            let ago = Int(now - seen)
            if ago < 5 {
                log("повтор через \(ago) с — пропущен", link, sender)
            } else {
                log("повтор через \(ago) с — спрашиваю", link, sender)
                repeated = request
            }
            return
        }
        recent[key] = now
        UserDefaults.standard.set(recent, forKey: Self.recentKey)
        log("принята", link, sender)
        start(request)
    }

    func acceptRepeated() {
        guard let r = repeated else { return }
        repeated = nil
        start(r)
    }

    private func start(_ r: IncomingRequest) {
        if let items = r.gallery {
            DownloadManager.shared.downloadGallery(title: r.title ?? "Карусель", items: items)
        } else {
            DownloadManager.shared.download(url: r.url, mode: r.mode, maxHeight: r.maxHeight, title: r.title)
        }
    }

    private func log(_ action: String, _ link: URL, _ sender: String) {
        let time = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withFullTime])
        let text = link.absoluteString
        let line = "\(time)  \(sender)  \(action)  \(text.count > 300 ? text.prefix(300) + "…" : Substring(text))\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Self.logURL)
        }
    }
}

// MARK: - Интерфейс

struct ContentView: View {
    @ObservedObject private var manager = DownloadManager.shared
    @ObservedObject private var setup = Setup.shared
    @ObservedObject private var inbox = Inbox.shared
    @AppStorage("folder") private var folder = NSHomeDirectory() + "/Downloads"
    @AppStorage("mode") private var modeRaw = Mode.video.rawValue
    @AppStorage("quality") private var qualityRaw = Quality.best.rawValue
    @AppStorage("compatible") private var compatible = false
    @State private var url = ""

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .video }
    private var quality: Quality { Quality(rawValue: qualityRaw) ?? .best }
    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var urlIsValid: Bool {
        guard let u = URL(string: trimmedURL), let scheme = u.scheme else { return false }
        return ["http", "https"].contains(scheme.lowercased()) && u.host != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                TextField("Ссылка на видео YouTube", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .onSubmit(start)
                Button("Вставить", action: paste).controlSize(.large)
                Button("Скачать", action: start)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!urlIsValid)
            }

            HStack(spacing: 16) {
                Picker("", selection: $modeRaw) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if mode == .video {
                    Picker("Качество", selection: $qualityRaw) {
                        ForEach(Quality.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .fixedSize()
                    Toggle("Для QuickTime (H.264)", isOn: $compatible)
                        .help("Выбирает H.264, который открывается везде. Обычно это не выше 1080p.")
                }
                Spacer()
            }

            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text((folder as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Button("Изменить…", action: chooseFolder).buttonStyle(.link)
                Spacer()
                Button("Открыть папку") { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
            }

            Divider()

            if manager.jobs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Вставьте ссылку и нажмите «Скачать»")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(manager.jobs) { JobRow(job: $0, manager: manager) }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            HStack {
                StatusButton(setup: setup)
                Spacer()
                if setup.checked && setup.extensionMissing {
                    Button("Расширение для браузера…") { setup.showSheet = true }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                if manager.jobs.contains(where: { !$0.isRunning }) {
                    Button("Очистить завершённые", action: manager.clearFinished)
                        .controlSize(.small)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 760)
        .onAppear {
            pasteIfEmpty()
            setup.refresh(openIfMissing: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if setup.checked && setup.busy == nil { setup.refresh() }
        }
        .alert("Эту ссылку уже присылали недавно", isPresented: Binding(
            get: { inbox.repeated != nil },
            set: { if !$0 { inbox.repeated = nil } }
        )) {
            Button("Скачать ещё раз") { inbox.acceptRepeated() }
            Button("Не нужно", role: .cancel) {}
        } message: {
            Text(inbox.repeated.map { $0.gallery != nil ? ($0.title ?? "") : $0.url } ?? "")
        }
        .sheet(isPresented: $setup.showSheet) { SetupSheet(setup: setup) }
        .alert(manager.alert ?? "", isPresented: Binding(
            get: { manager.alert != nil },
            set: { if !$0 { manager.alert = nil } }
        )) {
            Button("OK", role: .cancel) {}
        }
    }

    private func start() {
        guard urlIsValid else { return }
        guard setup.canDownload else {
            setup.showSheet = true
            return
        }
        download(trimmedURL, mode: mode)
        url = ""
    }

    /// maxHeight приходит из расширения (качество, выбранное на странице); иначе — из настроек окна.
    private func download(_ link: String, mode: Mode) {
        manager.download(url: link, mode: mode)
    }

    private func paste() {
        if let s = NSPasteboard.general.string(forType: .string) {
            url = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func pasteIfEmpty() {
        guard url.isEmpty, let s = NSPasteboard.general.string(forType: .string) else { return }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("youtube.com/") || t.contains("youtu.be/") { url = t }
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
}

struct JobRow: View {
    @ObservedObject var job: DownloadJob
    let manager: DownloadManager

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon.font(.title2).frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                Text(job.title).font(.headline).lineLimit(1).truncationMode(.middle)
                switch job.state {
                case .starting, .processing:
                    ProgressView().progressViewStyle(.linear)
                case .downloading:
                    ProgressView(value: job.progress)
                default:
                    EmptyView()
                }
                Text(job.detail)
                    .font(.caption)
                    .foregroundStyle(job.state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                if job.isRunning {
                    iconButton("xmark.circle", "Отменить загрузку", job.cancel)
                } else {
                    if hasFile {
                        iconButton("play.circle", "Открыть", openFile)
                        iconButton("folder.circle", "Открыть папку с файлом", revealFile)
                        iconButton("trash.circle", "Удалить файл с диска…", deleteFile)
                    }
                    if job.state == .failed || job.state == .cancelled {
                        iconButton("arrow.clockwise.circle", "Повторить") { manager.retry(job) }
                    }
                    iconButton("xmark.circle", "Удалить загрузку из списка (файл останется)") { manager.remove(job) }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        .contextMenu {
            if job.isRunning {
                Button("Отменить загрузку", action: job.cancel)
            } else {
                if hasFile {
                    Button("Открыть", action: openFile)
                    Button("Открыть папку с файлом", action: revealFile)
                    Divider()
                    Button("Удалить файл с диска…", action: deleteFile)
                }
                if job.state == .failed || job.state == .cancelled {
                    Button("Повторить") { manager.retry(job) }
                }
                Button("Удалить загрузку") { manager.remove(job) }
            }
        }
    }

    private var hasFile: Bool { job.state == .done && job.filePath != nil && !job.fileDeleted }

    private func openFile() {
        guard let path = job.filePath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealFile() {
        guard let path = job.filePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Файл уходит в Корзину, а не стирается насовсем — его можно вернуть.
    private func deleteFile() {
        guard let path = job.filePath else { return }
        let url = URL(fileURLWithPath: path)
        let alert = NSAlert()
        alert.messageText = "Удалить файл с диска?"
        alert.informativeText = "«\(url.lastPathComponent)» будет перемещён в Корзину."
        alert.addButton(withTitle: "В Корзину")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            job.fileDeleted = true
            job.detail = "Файл перемещён в Корзину"
        } catch {
            job.detail = "Не удалось удалить файл: \(error.localizedDescription)"
        }
    }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .starting, .downloading: Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
        case .processing: Image(systemName: "gearshape.circle").foregroundStyle(.orange)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.title3) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

// MARK: - Состояние компонентов

struct StatusButton: View {
    @ObservedObject var setup: Setup

    var body: some View {
        Button { setup.showSheet = true } label: {
            HStack(spacing: 6) {
                if setup.busy != nil || !setup.checked {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                Text(text).foregroundStyle(setup.allGood ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if !setup.allGood && setup.busy == nil && setup.checked {
                    Text(setup.waitingForTerminal ? "" : "Установить…").foregroundStyle(.tint)
                }
            }
            .font(.callout)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("yt-dlp, ffmpeg и deno: состояние, установка, обновление")
    }

    private var color: Color { setup.allGood ? .green : (setup.canDownload ? .orange : .red) }

    private var text: String {
        if let busy = setup.busy { return busy + "…" }
        if !setup.checked { return "Проверяю компоненты…" }
        if setup.waitingForTerminal { return "Идёт установка в Терминале…" }
        if setup.allGood {
            let v = setup.components.first?.version.map { " \($0)" } ?? ""
            return "Всё готово · yt-dlp\(v), ffmpeg, deno"
        }
        return "Не хватает: " + setup.missing.map(\.id).joined(separator: ", ")
    }
}

struct SetupSheet: View {
    @ObservedObject var setup: Setup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Компоненты").font(.title2.bold())
            Text("Приложение скачивает видео с помощью этих программ. Если чего-то нет, их можно поставить отсюда.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(setup.components) { c in
                    row(ok: c.installed, name: c.id, detail: c.purpose,
                        status: c.installed ? (c.version ?? "установлен") : "не установлен")
                    Divider()
                }
                row(ok: setup.brewPath != nil, name: "Homebrew", detail: "через него ставятся программы выше",
                    status: setup.brewPath != nil ? "установлен" : "не установлен")
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))

            VStack(spacing: 0) {
                if setup.browsers.isEmpty {
                    Text("Не нашёл Google Chrome или Яндекс Браузер в «Программах» — расширение ставить некуда.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                ForEach(Array(setup.browsers.enumerated()), id: \.element.id) { i, state in
                    if i > 0 { Divider() }
                    HStack(spacing: 10) {
                        Image(systemName: state.extensionInstalled ? "checkmark.circle.fill" : "puzzlepiece.extension.fill")
                            .foregroundStyle(state.extensionInstalled ? .green : .orange)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Расширение для \(state.browser.name)").font(.headline)
                            Text("кнопка «Скачать» под видео на YouTube")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(state.extensionInstalled ? "установлено" : "не установлено")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button(state.extensionInstalled ? "Переустановить" : "Установить") {
                            setup.installExtension(in: state.browser)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))

            if let browser = setup.extensionHelpFor {
                VStack(alignment: .leading, spacing: 6) {
                    Text("В \(browser.nameIn) открылась страница расширений, а в Finder — папка chrome-extension. Осталось:")
                    Text("Если страница не открылась, введите в адресной строке \(browser.extensionsPage)")
                        .foregroundStyle(.secondary)
                    Text("1. Включите «Режим разработчика» справа вверху страницы.")
                    Text("2. Перетащите папку chrome-extension из Finder на страницу. Или нажмите «Загрузить распакованное», затем ⌘⇧G, ⌘V (путь уже скопирован) и «Выбрать».")
                    Text("3. При первом «Скачать» на YouTube разрешите браузеру открывать приложение (галочка «Всегда разрешать»).")
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }

            if setup.waitingForTerminal {
                note("terminal", "Открыл Терминал с установкой. Введите там пароль администратора Mac, когда он попросит, и дождитесь слова «Готово». Состояние здесь обновится само, когда вернётесь в приложение.")
            } else if !setup.missing.isEmpty && setup.busy == nil {
                if setup.brewPath != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Будет выполнено:").font(.callout).foregroundStyle(.secondary)
                        Text(setup.installCommand)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    }
                } else {
                    note("key", "Homebrew нет, поэтому установка пойдёт в Терминале: сначала Homebrew (попросит пароль администратора Mac), затем \(setup.missing.map(\.id).joined(separator: ", ")).")
                }
            }

            if !setup.log.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(setup.log)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(setup.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(height: 120)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .onChange(of: setup.log) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
            }

            HStack {
                Button("Проверить заново") { setup.refresh() }
                    .disabled(setup.busy != nil)
                if setup.components.first?.installed == true && setup.brewPath != nil {
                    Button("Обновить yt-dlp", action: setup.updateYtdlp)
                        .disabled(setup.busy != nil)
                        .help("Если YouTube перестал отдавать видео, обычно помогает обновление")
                }
                Spacer()
                if let busy = setup.busy {
                    ProgressView().controlSize(.small)
                    Text(busy + "…").foregroundStyle(.secondary)
                } else if !setup.missing.isEmpty && !setup.waitingForTerminal {
                    Button(setup.brewPath != nil ? "Установить" : "Установить в Терминале", action: setup.installMissing)
                        .buttonStyle(.borderedProminent)
                }
                Button(setup.allGood ? "Готово" : "Закрыть") { dismiss() }
                    .keyboardShortcut(setup.allGood ? .defaultAction : .cancelAction)
            }
        }
        .padding(24)
        .frame(width: 600)
    }

    private func row(ok: Bool, name: String, detail: String, status: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(status)
                .font(.callout.monospacedDigit())
                .foregroundStyle(ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

// MARK: - Прогресс на значке в Доке

/// Значок в Доке всегда рисует приложение: иначе Док берёт иконку из бандла, а macOS
/// в тёмном режиме иконок перекрашивает её в чёрную. Пока идут загрузки — поверх
/// полоса общего прогресса, а если загрузок несколько — их число в кружке.
final class DockProgress {
    static let shared = DockProgress()
    private let view = DockProgressView()
    private var timer: Timer?

    /// Красный значок без полосы — при запуске и когда загрузки закончились.
    func showIdle() {
        let tile = NSApp.dockTile
        view.progress = nil
        view.frame = NSRect(origin: .zero, size: tile.size)
        tile.contentView = view
        tile.badgeLabel = nil
        tile.display()
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.update() }
        update()
    }

    private func update() {
        let tile = NSApp.dockTile
        let running = DownloadManager.shared.jobs.filter(\.isRunning)
        guard !running.isEmpty else {
            timer?.invalidate()
            timer = nil
            showIdle()
            // приложение в фоне — значок один раз подпрыгнет, что всё готово
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            return
        }
        // обработка (склейка, перекодирование) считается почти готовой загрузкой
        let values = running.map { job -> Double in
            switch job.state {
            case .downloading: return job.progress
            case .processing: return 1
            default: return 0
            }
        }
        view.progress = values.reduce(0, +) / Double(values.count)
        view.frame = NSRect(origin: .zero, size: tile.size)
        tile.contentView = view
        tile.badgeLabel = running.count > 1 ? String(running.count) : nil
        tile.display()
    }
}

final class DockProgressView: NSView {
    var progress: Double?  // nil — без полосы

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        guard let progress else { return }
        // полоса — в нижней части плашки значка (плашка занимает 10–90 % по сетке macOS)
        let track = NSRect(x: bounds.width * 0.19, y: bounds.height * 0.145,
                           width: bounds.width * 0.62, height: bounds.height * 0.10)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        let inner = track.insetBy(dx: track.height * 0.2, dy: track.height * 0.2)
        let width = max(inner.height, inner.width * CGFloat(min(max(progress, 0), 1)))
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: width, height: inner.height),
                     xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
    }
}

// MARK: - Приложение

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Главное окно создаёт само приложение, а не SwiftUI-сцена: при запуске в фоне
    // (например, браузером по ссылке) SwiftUI окно не открывает, а открыть его из кода нельзя.
    private var window: NSWindow?

    func showMainWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 800),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Загрузка видео"
            let host = NSHostingController(rootView: ContentView())
            host.sizingOptions = [.minSize]  // SwiftUI задаёт только минимум, иначе сжимает окно до него
            w.contentViewController = host
            w.setContentSize(NSSize(width: 740, height: 800))
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("MainWindow")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // Клик по значку в Доке, когда окно закрыто или свёрнуто.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // В тёмном режиме иконок macOS перекрашивает иконку из бандла; картинку, заданную так, Док рисует как есть.
    func applicationDidFinishLaunching(_ notification: Notification) {
        BrowserExtension.refreshIfInstalled()
        TempFiles.removeAll()
        showMainWindow()
        if let url = Bundle.main.url(forResource: "DockIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
            DockProgress.shared.showIdle()
            // Иконку из бандла macOS в тёмном режиме перекрашивает в чёрную, «свою» иконку
            // (как через «Свойства» в Finder) — нет. Ставим её, если её нет, — в том числе
            // после переноса приложения на другой Mac.
            let bundle = Bundle.main.bundlePath
            if !FileManager.default.fileExists(atPath: bundle + "/Icon\r") {
                NSWorkspace.shared.setIcon(image, forFile: bundle, options: [])
            }
        }
    }

    // Ссылки videoloader:// принимаются своим обработчиком Apple Event, а не через SwiftUI:
    // так каждая ссылка приходит ровно один раз и виден отправитель.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let link = URL(string: string) else { return }
        let pid = event.attributeDescriptor(forKeyword: AEKeyword(0x73706964))?.int32Value  // 'spid' — PID отправителя
        let sender = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
            ?? pid.map { "pid \($0)" } ?? "неизвестно"
        Inbox.shared.receive(link, from: sender)
        showMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Выход во время загрузки: спросить, а при выходе остановить yt-dlp и стереть недокачанное.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = RunningProcesses.count
        guard running > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = running == 1 ? "Идёт загрузка" : "Идут загрузки: \(running)"
        alert.informativeText = "Если выйти, загрузка остановится, а недокачанные файлы будут удалены."
        alert.addButton(withTitle: "Остаться")
        alert.addButton(withTitle: "Выйти")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        RunningProcesses.stopAll()
        TempFiles.removeAll()
    }
}

@main
struct VideoLoaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Главное окно — в AppDelegate.showMainWindow(); SwiftUI-сцене нужна хотя бы одна сцена.
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) {} }  // без пустого пункта «Настройки…»
    }
}
