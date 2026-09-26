import SwiftUI
import AppKit
import SafariServices

// MARK: - Настройки загрузки

enum Mode: String, CaseIterable, Identifiable {
    case video = "Видео"
    case audioM4A = "Звук m4a"
    case audioMP3 = "Звук mp3"
    var id: String { rawValue }
}

/// Как называть файл (меню «Имя файла ▾» в строке настроек). Автор и дата — из сведений сайта; нет их — только название.
enum NameStyle: String, CaseIterable {
    case title, author, date

    var menuTitle: String {
        switch self {
        case .title: "Название"
        case .author: "Автор — Название"
        case .date: "Дата Название"
        }
    }

    /// Что поставить перед названием (шаблон yt-dlp). `&{} — |` — с разделителем, если поле есть, иначе пусто.
    /// Instagram и Threads: расширение присылает «@автор — текст» — автор уже в названии.
    func decoration(title: String?) -> String {
        switch self {
        case .title: ""
        case .author: title?.hasPrefix("@") == true ? "" : "%(uploader,channel&{} — |)s"
        case .date: "%(upload_date>%Y-%m-%d&{} |)s"
        }
    }
}

enum Quality: Int, CaseIterable, Identifiable {
    case best = 0, p2160 = 2160, p1440 = 1440, p1080 = 1080, p720 = 720, p480 = 480
    var id: Int { rawValue }
    var title: String { self == .best ? "Максимальное" : "\(rawValue)p" }
}

enum Tools {
    /// `open --env DOWNMAX_FRESH=1 -a DownMax` — как на чистом Mac: Homebrew и прочие установки не видны
    /// (проверять установку компонентов и снимать мастер).
    static let fresh = ProcessInfo.processInfo.environment["DOWNMAX_FRESH"] != nil

    static let searchPath = (fresh ? [] : [
        "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
        NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.deno/bin",
    ]) + [
        ToolFolder.bin, ToolFolder.bundled,  // свои — после Homebrew: если программа уже стоит, берём её
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

// MARK: - Расширение для браузера (Chrome)

/// Браузер на движке Chromium, куда можно загрузить распакованное расширение.
enum Browser: String, CaseIterable, Identifiable {
    case chrome
    var id: String { rawValue }

    var name: String {
        switch self {
        case .chrome: "Google Chrome"
        }
    }

    /// Название в предложном падеже: «в Google Chrome».
    var nameIn: String {
        switch self {
        case .chrome: "Google Chrome"
        }
    }

    var appPath: String {
        switch self {
        case .chrome: "/Applications/Google Chrome.app"
        }
    }

    var extensionsPage: String {
        switch self {
        case .chrome: "chrome://extensions"
        }
    }

    var profilesDir: String {
        switch self {
        case .chrome: NSHomeDirectory() + "/Library/Application Support/Google/Chrome"
        }
    }

    var bundleID: String {
        switch self {
        case .chrome: "com.google.Chrome"
        }
    }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: appPath) }

    /// Отметка «от этого браузера пришла ссылка downmax://» — значит, новое расширение стоит и работает.
    /// Нужна потому, что папку профиля браузера macOS без разрешения пользователя читать не даёт.
    private var seenKey: String { "extensionSeen." + id }
    var extensionSeen: Bool {
        get { UserDefaults.standard.bool(forKey: seenKey) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }

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
    static let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/DownMax/chrome-extension")
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

/// Расширение для Safari вшито в приложение (PlugIns/DownMax Safari.appex), Safari находит его сам.
/// Есть только в своей сборке с сертификатом разработчика, в релизе его нет.
/// Включить его может только пользователь — приложение лишь открывает нужную страницу настроек Safari.
enum SafariExtension {
    static let id = "local.ohlexlexa.downmax.safari"

    enum State { case absent, disabled, enabled }

    /// Своя сборка с Safari: обновляется пересборкой, а не из релизов (там Safari нет).
    static var isBundled: Bool {
        Bundle.main.builtInPlugInsURL
            .map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("DownMax Safari.appex").path) } == true
    }

    /// absent — приложение собрано без расширения (релиз, нет сертификата) или Safari о нём не знает.
    static func check(_ done: @escaping (State) -> Void) {
        guard isBundled else { return done(.absent) }
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: id) { state, error in
            done(state.map { $0.isEnabled ? .enabled : .disabled } ?? .absent)
        }
    }

    static func openSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: id) { _ in }
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
        Component(id: "yt-dlp", purpose: "скачивает видео с YouTube, VK и других сайтов", versionArgs: ["--version"],
                  parseVersion: { $0 }),
        Component(id: "ffmpeg", purpose: "склеивает видео со звуком, делает mp3", versionArgs: ["-version"],
                  parseVersion: {  // «ffmpeg version 9.0.2-https://…» у сборки Мартина Ридля — только номер
                      ($0.split(separator: " ").dropFirst(2).first.map(String.init) ?? $0)
                          .split(separator: "-https").first.map(String.init) ?? $0 }),
        Component(id: "deno", purpose: "нужен yt-dlp, чтобы проходить защиту YouTube", versionArgs: ["--version"],
                  parseVersion: { $0.split(separator: " ").dropFirst().first.map(String.init) ?? $0 }),
        Component(id: "aria2c", purpose: "качает торренты", versionArgs: ["--version"],
                  parseVersion: { $0.split(separator: " ").last.map(String.init) ?? $0 }),
    ]
    @Published var brewPath: String?
    @Published var safari: SafariExtension.State = .absent
    @Published var checked = false
    @Published var busy: String?
    @Published var log = ""
    @Published var failed = false
    @Published var showSheet = false
    /// Ход установки от 0 до 1, пока DownMax скачивает компоненты.
    @Published var progress: Double?
    /// Уже скачанные за эту установку — «готово» в мастере, пока качаются остальные.
    @Published var placed: Set<String> = []
    @Published var browsers: [BrowserState] = []
    @Published var extensionHelpFor: Browser?

    var extensionMissing: Bool { !browsers.isEmpty && !browsers.contains(where: \.extensionInstalled) }

    var missing: [Component] { components.filter { !$0.installed } }
    var allGood: Bool { checked && missing.isEmpty }
    var canDownload: Bool { checked && components.prefix(2).allSatisfy(\.installed) }
    /// Сколько скачает «Установить», МБ.
    var downloadSize: Int { missing.flatMap { ComponentDownload.files(for: $0.id) }.map(\.megabytes).reduce(0, +) }

    func refresh(openIfMissing: Bool = false, then done: (() -> Void)? = nil) {
        SafariExtension.check { state in DispatchQueue.main.async { self.safari = state } }
        let current = components
        DispatchQueue.global(qos: .userInitiated).async {
            var updated = current
            for i in updated.indices {
                // aria2c — свой, из приложения: у Homebrew-версии встроенный DNS на macOS не находит серверы
                let path = updated[i].id == "aria2c" ? Aria2.path : Tools.find(updated[i].id)
                updated[i].path = path
                updated[i].version = path
                    .flatMap { Tools.firstLine($0, updated[i].versionArgs) }
                    .map(updated[i].parseVersion)
            }
            let brew = Tools.find("brew")
            let browsers = Browser.allCases.filter(\.isInstalled)
                // как на чистом Mac — расширение ещё не стоит (проверять мастер)
                .map { BrowserState(browser: $0, extensionInstalled: Tools.fresh ? self.confirmed.contains($0)
                                                                                  : $0.extensionSeen || $0.hasExtension) }
            DispatchQueue.main.async {
                self.components = updated
                self.brewPath = brew
                self.browsers = browsers
                if let b = self.extensionHelpFor, browsers.first(where: { $0.browser == b })?.extensionInstalled == true {
                    self.extensionHelpFor = nil
                }
                self.checked = true
                done?()
                Stats.checked(self)
                // без aria2c качается всё, кроме торрентов, — ради него окно само не открываем
                if openIfMissing && self.missing.contains(where: { $0.id != "aria2c" }) { self.showSheet = true }
            }
        }
    }

    /// От браузера пришла ссылка от нового расширения — показать «установлено», не читая его настройки.
    /// Расширения, отозвавшиеся за этот запуск (в режиме DOWNMAX_FRESH других признаков не берём).
    private var confirmed: Set<Browser> = []

    func extensionWorks(in browser: Browser) {
        confirmed.insert(browser)
        guard !browser.extensionSeen else { return }
        browser.extensionSeen = true
        if let i = browsers.firstIndex(where: { $0.browser == browser }) { browsers[i].extensionInstalled = true }
        if extensionHelpFor == browser { extensionHelpFor = nil }
    }

    func installExtension(in browser: Browser) {
        browser.extensionSeen = false  // переустановка: ждём первую ссылку заново
        guard BrowserExtension.sync() else {
            failed = true
            log = "Не удалось распаковать расширение в \(BrowserExtension.folder.path)"
            return
        }
        // Путь — на случай «Загрузить распакованное» (⌘⇧G, ⌘V). Папку не открываем в Finder: Chrome перекрывал её,
        // и новичок застревал. Вместо этого подсказка поверх всех окон, папку тащат прямо с неё.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(BrowserExtension.folder.path, forType: .string)
        ExtensionHelper.show(for: browser)
        if let page = URL(string: browser.extensionsPage) {
            NSWorkspace.shared.open([page], withApplicationAt: URL(fileURLWithPath: browser.appPath),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
        extensionHelpFor = browser
    }

    /// Скачивает то, чего нет (или обновляет yt-dlp): без Homebrew, Терминала и пароля.
    func installMissing() {
        install(missing.map(\.id).filter { !ComponentDownload.files(for: $0).isEmpty })
    }

    func install(_ ids: [String], title: String? = nil) {
        guard !ids.isEmpty, busy == nil else { return }
        busy = title ?? "Скачиваю " + ids.joined(separator: ", ")
        progress = 0
        placed = []
        failed = false
        log = ""
        Task {
            do {
                try await ComponentDownload.install(ids, progress: { fraction, label in
                    self.progress = fraction
                    self.busy = label
                }, placed: { self.placed.insert($0) })
                await MainActor.run { self.finishInstall(nil) }
            } catch {
                await MainActor.run { self.finishInstall(error) }
            }
        }
    }

    private func finishInstall(_ error: Error?) {
        progress = nil
        if let error {
            busy = nil
            failed = true
            log = "Не удалось скачать: \(error.localizedDescription)\nПроверьте интернет и нажмите «Установить» ещё раз."
            refresh()
        } else {
            // Первый запуск новых программ macOS проверяет 10–15 с — пока идёт проверка, не показывать «не установлен».
            busy = "Проверяю программы"
            refresh(then: { self.busy = nil })
        }
    }

    /// yt-dlp из Homebrew обновляет Homebrew, поставленный DownMax — DownMax (скачивает заново), прочий — сам yt-dlp.
    func updateYtdlp() {
        guard let path = components.first(where: { $0.id == "yt-dlp" })?.path else { return }
        let real = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? path
        if real.contains("/Cellar/yt-dlp/") {
            runBrew(["upgrade", "yt-dlp"], title: "Обновляю yt-dlp")
        } else if ToolFolder.owns(path) {
            install(["yt-dlp"], title: "Обновляю yt-dlp")
        } else {
            busy = "Обновляю yt-dlp"
            DispatchQueue.global().async {
                _ = Tools.firstLine(path, ["-U"])
                DispatchQueue.main.async { self.busy = nil; self.refresh() }
            }
        }
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
}

/// title — имя файла, когда у источника своего названия нет (поток GetCourse приходит без него).
/// prefix — номер перед названием ролика в плейлисте («01» → «01 Введение»): название подставит yt-dlp.
func buildArguments(mode: Mode, maxHeight: Int?, compatible: Bool, subtitles: Bool = false, nameStyle: NameStyle = .title,
                    folder: String, url: String, title: String? = nil, prefix: String? = nil) -> [String] {
    // В шаблонах yt-dlp «%» — служебный символ, в готовом названии его надо удвоить.
    let fixedTitle = title.map { sanitizeFilename($0).replacingOccurrences(of: "%", with: "%%") }
        ?? prefix.map { sanitizeFilename($0).replacingOccurrences(of: "%", with: "%%") + " %(title)s" }
    // Имя файла: номер в плейлисте (если есть) → автор или дата → название.
    let number = title == nil ? prefix.map { sanitizeFilename($0).replacingOccurrences(of: "%", with: "%%") + " " } ?? "" : ""
    let bareTitle = title.map { sanitizeFilename($0).replacingOccurrences(of: "%", with: "%%") } ?? "%(title)s"
    let fileName = number + nameStyle.decoration(title: title) + bareTitle
    var args = [
        "--no-playlist", "--newline", "--progress", "--no-simulate",
        "--print", "before_dl:TITLE " + (fixedTitle ?? "%(title)s"),
        "--print", "after_move:FILE %(filepath)s",
        "--progress-template",
        "download:PROG %(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
        "-P", folder,
        "-o", fileName + ".%(ext)s",
        // главы YouTube — внутрь файла (QuickTime: » на панели управления → «Главы»); если глав нет, ничего не меняется
        "--embed-chapters",
        // название, автор, дата — в теги файла (их показывают Музыка, QuickTime, Finder)
        "--embed-metadata",
    ]
    switch mode {
    case .video:
        let cap = maxHeight.map { ":\($0)" } ?? ""
        // compatible: сразу H.264, даже если так ниже разрешение (обычно до 1080p), — без перекодирования.
        // Иначе — лучшее разрешение, а среди равных H.264 и AAC; VP9/AV1/Opus потом перекодируются
        // (см. needsQuickTimeConversion), чтобы файл открывался в QuickTime.
        let sort = compatible ? "vcodec:h264,res\(cap),acodec:aac" : "res\(cap),vcodec:h264,acodec:aac"
        args += ["-f", "bv*+ba/b", "-S", sort, "--merge-output-format", "mp4"]
        if subtitles {
            // Только авторские субтитры (автоматические YouTube — без знаков препинания и часто 429), русские
            // и английские — дорожками внутрь mp4 (QuickTime: «Вид → Субтитры»; .srt он не открывает).
            // Без --write-subs: с ним yt-dlp оставляет рядом .vtt. --ignore-errors: не скачались субтитры —
            // видео всё равно сохраняется (иначе yt-dlp бросает загрузку).
            args += ["--sub-langs", "ru.*,en.*", "--embed-subs", "--ignore-errors"]
        }
    case .audioM4A:
        // «/b»: у прямого mp4 (Threads, файл по ссылке) отдельной звуковой дорожки нет — звук берётся из видео
        args += ["-f", "ba[ext=m4a]/ba/b", "-x", "--audio-format", "m4a"]
    case .audioMP3:
        args += ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"]
    }
    if mode != .video {
        // обложка ролика — внутрь звука (webp у YouTube плееры не читают, поэтому jpg); нет обложки — не ошибка
        args += ["--embed-thumbnail", "--convert-thumbnails", "jpg"]
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

/// Ролик VK, открытый поверх ленты или стены (vk.com/feed?z=video-1_2%2F…), yt-dlp не узнаёт.
/// Ссылки VK с /video-1_2, /clip-1_2 или z=video-1_2 превращаются в vkvideo.ru/video-1_2.
func vkVideoURL(_ raw: String) -> String? {
    guard let u = URLComponents(string: raw), let host = u.host?.lowercased(),
          ["vk.com", "vk.ru", "vkvideo.ru"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
          let m = (raw.removingPercentEncoding ?? raw).firstMatch(of: #/(video|clip)(-?\d+)_(\d+)/#)
    else { return nil }
    return "https://vkvideo.ru/\(m.1)\(m.2)_\(m.3)"
}

/// Threads yt-dlp не знает. Пост (и ссылку «Поделиться» threads.com/share/…) приложение открывает само:
/// без «браузерного» User-Agent Threads сразу отдаёт страницу с данными поста (браузеру — заготовку,
/// которую достраивает скрипт) и переадресует share-ссылку на пост. Из данных берутся прямые mp4,
/// как в окошке расширения (popup.js, threadsFromHtml).
enum ThreadsLink {
    struct Video {
        let url: String
        let title: String
    }

    static func isThreads(_ raw: String) -> Bool {
        guard let host = URL(string: raw)?.host?.lowercased() else { return false }
        return ["threads.com", "threads.net"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func videos(_ raw: String) async throws -> [Video] {
        guard let url = URL(string: raw) else { throw failure("Не похоже на ссылку Threads.") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("DownMax", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let final = response.url?.absoluteString ?? raw
        guard let code = final.firstMatch(of: #/\/post\/([\w-]+)/#)?.1 else {
            throw failure("Ссылка Threads не ведёт на пост.")
        }
        let html = String(decoding: data, as: UTF8.self)
        var post: [String: Any]?
        for m in html.matches(of: #/<script type="application\/json"[^>]*>(.*?)<\/script>/#.dotMatchesNewlines()) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(m.1.utf8)) else { continue }
            find(String(code), in: json, depth: 0, found: &post)
        }
        guard let post else { throw failure("Threads не отдал пост. Скорее всего, он закрыт или удалён.") }

        let user = (post["user"] as? [String: Any])?["username"] as? String
        let caption = ((post["caption"] as? [String: Any])?["text"] as? String ?? "")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }.map { String($0.prefix(80)) }
        let media = (post["carousel_media"] as? [[String: Any]]) ?? [post]
        let urls = media.compactMap { m -> String? in
            let versions = m["video_versions"] as? [[String: Any]] ?? []
            return versions.max { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }?["url"] as? String
        }
        guard !urls.isEmpty else { throw failure("В этом посте Threads нет видео.") }
        let base = (user.map { "@" + $0 } ?? "Threads") + " — " + (caption ?? String(code))
        return urls.enumerated().map { i, u in
            Video(url: u, title: urls.count > 1 ? "\(base) (\(i + 1))" : base)
        }
    }

    /// Один пост встречается в данных несколько раз, иногда урезанной копией — копия с видео важнее.
    private static func find(_ code: String, in o: Any, depth: Int, found: inout [String: Any]?) {
        guard depth < 60 else { return }
        if let list = o as? [Any] {
            for x in list { find(code, in: x, depth: depth + 1, found: &found) }
        } else if let dict = o as? [String: Any] {
            if dict["code"] as? String == code, dict["video_versions"] != nil || dict["carousel_media"] != nil {
                if found == nil || (!hasVideo(found!) && hasVideo(dict)) { found = dict }
            }
            for v in dict.values { find(code, in: v, depth: depth + 1, found: &found) }
        }
    }

    private static func hasVideo(_ post: [String: Any]) -> Bool {
        !((post["video_versions"] as? [Any]) ?? []).isEmpty
            || ((post["carousel_media"] as? [[String: Any]]) ?? []).contains { !(($0["video_versions"] as? [Any]) ?? []).isEmpty }
    }

    private static func failure(_ text: String) -> Error {
        NSError(domain: "DownMax", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
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
/// У каждой загрузки своя подпапка; она живёт, пока загрузка в списке и не завершена (в том числе
/// на паузе и между запусками), и удаляется при завершении, отмене или удалении из списка.
enum TempFiles {
    static let folder = NSHomeDirectory() + "/Library/Caches/DownMax"

    static func folder(for id: UUID) -> String { folder + "/" + id.uuidString }

    static func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Всё, кроме кусков загрузок, которые стоят в списке на паузе или продолжатся после запуска.
    static func removeAll(except keep: Set<UUID> = []) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        for name in names where !keep.contains(where: { $0.uuidString == name }) { remove(folder + "/" + name) }
    }
}

/// Где теперь готовый файл, если по старому пути его нет.
enum FileTracking {
    static func bookmark(_ path: String) -> Data? {
        try? URL(fileURLWithPath: path).bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// 1) По закладке — переименовали или перенесли (в Корзине — не считается: файла для пользователя нет).
    /// 2) Без закладки (файл пропал раньше, чем она появилась) — «имя 05.58.26.mp4» в той же папке: так macOS
    ///    называет файл, возвращённый из Корзины, если там уже лежал файл с тем же именем.
    static func find(_ path: String, bookmark: Data?) -> String? {
        let fm = FileManager.default
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               !url.path.contains("/.Trash/"), fm.fileExists(atPath: url.path) {
                return url.path
            }
        }
        let url = URL(fileURLWithPath: path)
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return nil }
        let pattern = "^" + NSRegularExpression.escapedPattern(for: stem) + " \\d{2}\\.\\d{2}\\.\\d{2}"
            + (ext.isEmpty ? "" : "\\." + NSRegularExpression.escapedPattern(for: ext)) + "$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = names.filter { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        return matches.count == 1 ? folder.appendingPathComponent(matches[0]).path : nil  // двое — не угадываем
    }
}

/// До версии 2.0 приложение называлось «Загрузка видео» (local.ohlexlexa.videoloader).
/// Настройки переносятся один раз, временные файлы и журнал старого имени удаляются.
/// Папку старого расширения (Application Support/VideoLoader) не трогаем: браузер грузит его оттуда,
/// и оно работает, пока пользователь не поставит расширение заново из «Компонентов».
enum OldName {
    static func migrate() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromVideoLoader") else { return }
        if let old = UserDefaults(suiteName: "local.ohlexlexa.videoloader") {
            for key in ["folder", "mode", "compatible", "quality"] where d.object(forKey: key) == nil {
                if let value = old.object(forKey: key) { d.set(value, forKey: key) }
            }
        }
        d.set(true, forKey: "migratedFromVideoLoader")
        let lib = NSHomeDirectory() + "/Library"
        TempFiles.remove(lib + "/Caches/VideoLoader")
        TempFiles.remove(lib + "/Logs/VideoLoader.log")
        TempFiles.remove(lib + "/Caches/local.ohlexlexa.videoloader")
    }
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
    enum State: String, Codable { case queued, starting, downloading, processing, paused, done, failed, cancelled }

    /// Что хранится между запусками (Application Support/DownMax/downloads.json).
    struct Record: Codable {
        let id: UUID
        let url: String
        let arguments: [String]
        let title: String
        let gallery: [GalleryItem]?
        let galleryTarget: String?
        let state: State
        let detail: String
        let progress: Double
        let filePath: String?
        let fileDeleted: Bool
        let amounts: String?
        let converting: Bool   // выход пришёлся на перекодирование — повторить его при запуске
        let added: Date?       // у записей до 2.0 — нет
        var finished: Date? = nil   // когда загрузка завершилась
        var note: String? = nil     // пометка к «Готово»: «3 фото и 2 видео», «без перекодирования»
        var page: String? = nil     // страница, откуда взято (пост Threads, урок GetCourse)
        var fileBookmark: Data? = nil  // закладка macOS на готовый файл: находит его после переименования и переноса
        var error: String? = nil    // исходный текст ошибки (в строке — понятный, этот — в подробностях и в отзыве)
        var origin: String? = nil   // откуда пришла ссылка: field, chrome, safari, iphone, clipboard — для статистики
    }

    let id: UUID
    let url: String
    let arguments: [String]
    @Published var title: String
    /// Окно показывает «Очистить завершённые» по состояниям загрузок — сообщаем ему о смене,
    /// а список загрузок сохраняется на диск.
    @Published var state: State = .starting {
        willSet { DownloadManager.shared.objectWillChange.send() }
        didSet {
            DownloadManager.shared.save()
            if oldValue != state { DownloadQueue.tick() }  // освободилось место — запустить ждущие
        }
    }
    @Published var progress: Double = 0
    /// Ход перекодирования 0…1; nil — перекодирования нет или длительность неизвестна
    @Published var convertProgress: Double? = nil
    @Published var detail = "Получаю сведения о видео…"
    @Published var filePath: String?
    @Published var fileDeleted = false
    /// Закладка macOS на готовый файл (как у Finder в «Недавних»): по ней файл находится, даже если его переименовали,
    /// перенесли в другую папку или вернули из Корзины под новым именем.
    var fileBookmark: Data?
    /// Скорость загрузки, пока качается (для строки внизу окна «↓ 5 МБ/с»).
    @Published var speed: Double = 0
    let added: Date?
    /// Страница, откуда взято, когда `url` — временная ссылка на файл (видео Threads, поток GetCourse, карусель).
    let page: String?
    /// Когда загрузка завершилась — дата в строке «Готово · 12 МБ · сегодня, 14:05».
    @Published var finished: Date?
    /// Пометка к «Готово» (без имени файла — оно и так в заголовке строки).
    @Published var note: String?
    /// Исходный текст ошибки (yt-dlp, сеть): в строке списка — перевод на человеческий, этот — в подробностях.
    @Published var error: String?
    /// Откуда пришла ссылка (для статистики): field, chrome, safari, iphone, clipboard.
    let origin: String?
    /// Когда началась загрузка и перекодирование в этом запуске — длительность для статистики.
    private var startedAt: Date?
    private var convertStartedAt: Date?

    private var process: Process?
    private var lastError: String?
    private var cancelled = false
    private var pausing = false
    private var requeuing = false
    /// «12 МБ из 80 МБ» — для строки на паузе.
    private(set) var amounts: String?
    /// Набор файлов по прямым ссылкам (карусель Instagram): качается без yt-dlp.
    let gallery: [GalleryItem]?
    let galleryTarget: String?
    private var task: Task<Void, Never>?

    var isRunning: Bool { [.starting, .downloading, .processing].contains(state) }
    /// Пауза — только пока качается: перекодирование или склейку на середине не продолжить.
    var canPause: Bool { [.starting, .downloading].contains(state) && convertProgress == nil }
    var isConverting: Bool { convertProgress != nil }

    init(url: String, arguments: [String], page: String? = nil, origin: String? = nil) {
        self.id = UUID()
        self.origin = origin
        self.page = page
        self.url = url
        self.arguments = arguments
        self.title = url
        self.gallery = nil
        self.galleryTarget = nil
        self.added = Date()
    }

    init(gallery: [GalleryItem], target: String, title: String, arguments: [String], page: String? = nil,
         origin: String? = nil) {
        self.id = UUID()
        self.origin = origin
        self.page = page
        self.url = "gallery"
        self.arguments = arguments
        self.title = title
        self.gallery = gallery
        self.galleryTarget = target
        self.added = Date()
    }

    init(record r: Record) {
        id = r.id
        url = r.url
        arguments = r.arguments
        title = r.title
        gallery = r.gallery
        galleryTarget = r.galleryTarget
        filePath = r.filePath
        fileDeleted = r.fileDeleted
        amounts = r.amounts
        progress = r.progress
        detail = r.detail
        added = r.added
        page = r.page
        finished = r.finished
        fileBookmark = r.fileBookmark
        error = r.error
        origin = r.origin
        // У записей до 2.0 пометка была внутри подписи «Готово · имя файла · пометка».
        let name = r.filePath.map { ($0 as NSString).lastPathComponent }
        note = r.note ?? {
            guard r.state == .done else { return nil }
            let rest = r.detail.components(separatedBy: " · ").dropFirst().filter { $0 != name && $0 != r.title }
            return rest.isEmpty ? nil : rest.joined(separator: " · ")
        }()
        state = r.state
    }

    func record(quitting: Bool) -> Record {
        Record(id: id, url: url, arguments: arguments, title: title, gallery: gallery, galleryTarget: galleryTarget,
               state: state, detail: detail, progress: progress, filePath: filePath, fileDeleted: fileDeleted,
               amounts: amounts, converting: quitting && isConverting, added: added, finished: finished, note: note, page: page,
               fileBookmark: fileBookmark, error: error, origin: origin)
    }

    /// Запуск или продолжение после паузы: yt-dlp докачивает куски из той же временной папки.
    func resume() {
        guard !isRunning else { return }
        cancelled = false
        pausing = false
        lastError = nil
        error = nil
        if startedAt == nil { startedAt = Date() }
        if gallery != nil { return startGallery() }
        guard let ytdlp = Tools.find("yt-dlp") else {
            state = .failed
            detail = "Не найден yt-dlp. Установите его в «Компонентах» внизу окна."
            return
        }
        state = .starting
        detail = amounts.map { $0 + " · продолжаю…" } ?? "Получаю сведения о видео…"
        start(ytdlp: ytdlp)
        DockProgress.shared.start()
    }

    /// Нет места в очереди (лимит очереди) — ждать; запустит DownloadQueue.
    func enqueue() {
        detail = (["В очереди", amounts].compactMap { $0 }).joined(separator: " · ")
        state = .queued
    }

    /// Пауза для ждущей в очереди (групповая «Пауза»): не запускать, пока не продолжат.
    func hold() {
        guard state == .queued else { return }
        detail = (["Пауза", amounts].compactMap { $0 }).joined(separator: " · ")
        state = .paused
    }

    /// Недокачанное остаётся во временной папке, пока загрузка в списке.
    func pause() {
        guard canPause else { return }
        Stats.send("pause", ["kind": statKind])
        pausing = true
        process?.terminate()
        task?.cancel()
    }

    /// При выходе: остановить, не меняя состояния, — при запуске загрузка продолжится.
    func stopForQuit() {
        pausing = true
        process?.terminate()
        task?.cancel()
    }

    private func markPaused() {
        pausing = false
        if requeuing {
            requeuing = false
            return enqueue()  // остановлена ради уменьшенного лимита — ждать своей очереди, а не «Пауза»
        }
        detail = (["Пауза", amounts].compactMap { $0 }).joined(separator: " · ")
        state = .paused
    }

    /// Лимит уменьшили (1 вместо 3) — вернуть в очередь: недокачанное остаётся, продолжится с того же места.
    func requeue() {
        guard canPause else { return }
        requeuing = true
        pausing = true
        process?.terminate()
        task?.cancel()
    }

    /// После перезапуска посреди перекодирования: файл уже в «Загрузках», перекодировать заново.
    func resumeConversion() {
        if let path = filePath, FileManager.default.fileExists(atPath: path), needsQuickTimeConversion(path) {
            convertForQuickTime(path)
            DockProgress.shared.start()
        } else {
            markDone()
        }
    }

    /// Скачивает файлы по очереди во временную папку и только в конце переносит их
    /// в «Загрузки»: одним файлом, если он один, или папкой с 01.jpg, 02.mp4…
    func startGallery() {
        guard let items = gallery, let target = galleryTarget else { return }
        if startedAt == nil { startedAt = Date() }
        state = .downloading
        DockProgress.shared.start()
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
                        throw NSError(domain: "DownMax", code: http.statusCode,
                                      userInfo: [NSLocalizedDescriptionKey: Failure.http(http.statusCode, file: i + 1),
                                                 "raw": "HTTP \(http.statusCode) на файл \(i + 1): \(item.u)"])
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
                TempFiles.remove(temp)  // карусель после паузы качается заново — файлы небольшие
                if pausing && !DownloadManager.shared.quitting {
                    progress = 0
                    markPaused()
                } else if pausing {
                    return
                } else if cancelled || error is CancellationError {
                    state = .cancelled
                    detail = "Отменено"
                    Stats.send("download_cancelled", statProps)
                } else {
                    self.error = (error as NSError).userInfo["raw"] as? String ?? String(describing: error)
                    detail = Failure.system(error)
                    state = .failed
                    Stats.send("download_failed", statProps.merging(["error": Failure.systemKind(error)]) { $1 })
                }
            }
        }
    }

    func start(ytdlp: String) {
        if startedAt == nil { startedAt = Date() }
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
            self.error = error.localizedDescription
            detail = "Не удалось запустить yt-dlp. Переустановите его в «Компонентах» внизу окна."
            state = .failed
            Stats.send("download_failed", statProps.merging(["error": "launch"]) { $1 })
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
        speed = f[3] ?? 0
        if progress >= 0.999 {
            speed = 0
            if state != .processing { state = .processing }
            detail = "Собираю файл…"
            return
        }
        if state != .downloading { state = .downloading }
        var parts: [String] = []
        amounts = total.map { "\(bytes(done)) из \(bytes($0))" } ?? bytes(done)
        parts.append(amounts!)
        if let speed = f[3] { parts.append("\(bytes(speed))/с") }
        if let eta = f[4] { parts.append("осталось \(duration(eta))") }
        detail = parts.joined(separator: " · ")
    }

    private func finish(status: Int32) {
        if let p = process { RunningProcesses.remove(p) }
        process = nil
        speed = 0
        if pausing {
            // Выход из приложения — состояние не трогаем: при запуске загрузка продолжится.
            if !DownloadManager.shared.quitting { markPaused() }
            return
        }
        TempFiles.remove(TempFiles.folder(for: id))
        if cancelled {
            state = .cancelled
            detail = "Отменено"
            Stats.send("download_cancelled", statProps)
        } else if status == 0 {
            if let path = filePath, needsQuickTimeConversion(path) {
                convertForQuickTime(path)
            } else {
                markDone()
            }
        } else {
            fail(lastError ?? "yt-dlp завершился с кодом \(status)")
        }
    }

    /// Строка — понятная фраза, исходный текст — в `error`. Если сайт изменился, подсказка называет дату версии yt-dlp:
    /// её узнаём отдельным запуском yt-dlp, не задерживая строку.
    private func fail(_ raw: String) {
        let temporary = gallery != nil || Source.isTemporary(url)
        error = raw
        detail = Failure.video(raw, temporary: temporary)
        state = .failed
        var props = statProps
        props["error"] = Failure.kind(raw, temporary: temporary)
        if let version = Stats.ytdlpVersion() { props["ytdlp"] = version }
        Stats.send("download_failed", props)
        // такие ошибки обычно лечит свежий yt-dlp
        if ["site_changed", "forbidden", "robot"].contains(props["error"] as? String ?? "") { YtdlpAutoUpdate.afterFailure() }
        guard Failure.needsVersion(raw), let ytdlp = Tools.find("yt-dlp") else { return }
        DispatchQueue.global().async {
            let version = Tools.firstLine(ytdlp, ["--version"])
            DispatchQueue.main.async {
                guard self.state == .failed, self.error == raw else { return }
                self.detail = Failure.video(raw, temporary: temporary, ytdlpVersion: version)
                DownloadManager.shared.save()
            }
        }
    }

    private func markDone(note: String? = nil) {
        var props = statProps
        if let startedAt { props["duration_s"] = Date().timeIntervalSince(startedAt) }
        if let size = fileSize { props["size_mb"] = Double(size) / 1_000_000 }
        props["converted"] = convertStartedAt != nil
        if let convertStartedAt { props["convert_s"] = Date().timeIntervalSince(convertStartedAt) }
        Stats.send("download_done", props)
        self.note = note
        finished = Date()
        progress = 1
        detail = (["Готово", note].compactMap { $0 }).joined(separator: " · ")
        state = .done
    }

    // Лучшее качество YouTube (2K, 4K) и Instagram приходит в VP9 или AV1, звук YouTube — часто Opus.
    // Их не открывают ни QuickTime, ни просмотр по пробелу. Такой файл перекодируется
    // аппаратным кодировщиком Mac: видео в H.264, звук в AAC; что и так подходит — копируется.
    private func streamCodec(_ path: String, _ stream: String) -> String? {
        guard let ffprobe = Tools.find("ffprobe") else { return nil }
        return Tools.firstLine(ffprobe, ["-v", "error", "-select_streams", stream,
                                         "-show_entries", "stream=codec_name", "-of", "default=nw=1:nk=1", path])
    }

    private func needsQuickTimeConversion(_ path: String) -> Bool {
        guard let video = streamCodec(path, "v:0"), !video.isEmpty else { return false }  // звук без видео не трогаем
        let audio = streamCodec(path, "a:0") ?? ""
        return ["vp9", "av1"].contains(video) || ["opus", "vorbis"].contains(audio)
    }

    private func convertForQuickTime(_ path: String) {
        guard let ffmpeg = Tools.find("ffmpeg") else { return markDone() }
        convertStartedAt = Date()
        state = .processing
        convertProgress = 0
        detail = "Перекодирую, чтобы видео открывалось в QuickTime…"

        let ffprobe = Tools.find("ffprobe")
        let probe = { (entry: String) in
            ffprobe.flatMap { Tools.firstLine($0, ["-v", "error", "-show_entries", "format=\(entry)", "-of", "default=nw=1:nk=1", path]) }
        }
        let videoNeeds = ["vp9", "av1"].contains(streamCodec(path, "v:0") ?? "")
        let audioNeeds = ["opus", "vorbis"].contains(streamCodec(path, "a:0") ?? "")
        let total = probe("duration").flatMap { Double($0) } ?? 0

        // H.264 сжимает хуже VP9 — битрейт берём вдвое выше исходного, в разумных пределах.
        let sourceRate = probe("bit_rate").flatMap { Int($0) } ?? 3_000_000
        let rate = min(max(sourceRate * 2, 3_000_000), 20_000_000)

        let folder = TempFiles.folder(for: id)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let output = folder + "/converted.mp4"

        var args = ["-y", "-v", "error", "-nostats", "-progress", "pipe:1", "-i", path,
                    "-map", "0:v:0", "-map", "0:a?", "-map", "0:s?", "-c:s", "copy", "-map_chapters", "0"]
        args += videoNeeds ? ["-c:v", "h264_videotoolbox", "-b:v", String(rate), "-tag:v", "avc1"] : ["-c:v", "copy"]
        args += audioNeeds ? ["-c:a", "aac", "-b:a", "192k"] : ["-c:a", "copy"]
        args += ["-movflags", "+faststart", output]

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = args
        p.environment = Tools.environment
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        // ffmpeg -progress пишет «out_time_us=…» — по нему считаем долю и оставшееся время
        let pipe = Pipe()
        p.standardOutput = pipe
        let started = Date()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            guard total > 0, let text = String(data: handle.availableData, encoding: .utf8),
                  let line = text.split(separator: "\n").last(where: { $0.hasPrefix("out_time_us=") }),
                  let us = Double(line.dropFirst("out_time_us=".count)) else { return }
            let share = min(max(us / 1_000_000 / total, 0), 1)
            DispatchQueue.main.async {
                guard self.state == .processing else { return }
                self.convertProgress = share
                var text = "Перекодирую для QuickTime · \(Int(share * 100))%"
                let spent = Date().timeIntervalSince(started)
                if share > 0.02 { text += " · осталось \(self.duration(spent / share - spent))" }
                self.detail = text
            }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                RunningProcesses.remove(proc)
                self.process = nil
                self.convertProgress = nil
                var note: String? = nil
                if self.cancelled {
                    note = "без перекодирования"
                } else if proc.terminationStatus == 0 {
                    do {
                        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                                  withItemAt: URL(fileURLWithPath: output))
                    } catch {
                        note = "перекодированный файл не сохранился, остался исходный"
                    }
                } else {
                    note = "без перекодирования, QuickTime может не открыть"
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
            convertProgress = nil
            markDone(note: "без перекодирования, QuickTime может не открыть")
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
    /// Сообщение пользователю — окном-вопросом по центру, даже если главное окно закрыто.
    /// Окно выбора роликов плейлиста или канала (playlist.swift).
    @Published var pendingPlaylist: PendingPlaylist?
    @Published var alert: String? {
        didSet { if let alert { DispatchQueue.main.async { self.alert = nil; Ask.run(alert) } } }
    }
    var quitting = false
    private var saveScheduled = false
    private static let listURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/DownMax/downloads.json")

    /// Список сохраняется между запусками, как у торрентов. Запись откладывается до конца
    /// текущего цикла, чтобы в файл попали и состояние, и подпись к нему.
    func save() {
        guard !saveScheduled, !quitting else { return }
        saveScheduled = true
        DispatchQueue.main.async {
            self.saveScheduled = false
            self.write(quitting: false)
        }
    }

    private func write(quitting: Bool) {
        let records = jobs.filter { $0.state != .cancelled }.map { $0.record(quitting: quitting) }
        try? FileManager.default.createDirectory(at: Self.listURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: Self.listURL) }
    }

    /// При запуске: вернуть список. Возвращает загрузки, чьи недокачанные куски надо сохранить.
    func restore() -> Set<UUID> {
        guard let data = try? Data(contentsOf: Self.listURL),
              let records = try? JSONDecoder().decode([DownloadJob.Record].self, from: data) else { return [] }
        jobs = records.map(DownloadJob.init(record:))
        return Set(records.filter { [.starting, .downloading, .processing, .paused].contains($0.state) }.map(\.id))
    }

    /// После уборки временных файлов: продолжить то, что шло при выходе.
    func resumeAfterLaunch() {
        guard let data = try? Data(contentsOf: Self.listURL),
              let records = try? JSONDecoder().decode([DownloadJob.Record].self, from: data) else { return }
        for r in records {
            guard let job = jobs.first(where: { $0.id == r.id }) else { continue }
            if r.converting { job.resumeConversion() }
            // шли при выходе — в очередь, запустятся по лимиту (как и ждавшие)
            else if [.starting, .downloading, .processing].contains(r.state) { job.enqueue() }
        }
        DownloadQueue.tick()
    }

    /// При выходе: запомнить, что шло, и остановить без удаления недокачанного.
    func stopAllForQuit() {
        write(quitting: true)
        quitting = true
        jobs.filter(\.isRunning).forEach { $0.stopForQuit() }
    }

    /// Параметры, которых нет в запросе, берутся из настроек окна (UserDefaults, как у @AppStorage).
    /// page — страница, откуда взято, если `rawURL` — временная ссылка на файл (видео Threads, поток GetCourse).
    func download(url rawURL: String, mode: Mode? = nil, maxHeight: Int? = nil, title: String? = nil, page: String? = nil,
                  folder chosenFolder: String? = nil, prefix: String? = nil, names: [String: String]? = nil,
                  displayTitle: String? = nil, origin: String = "field") {
        // Плейлист или канал — окно выбора роликов; одиночное видео (и watch?v=…&list=…) — как раньше.
        // title здесь — название плейлиста со страницы (у VK yt-dlp его не знает).
        if let list = Playlist.listURL(rawURL) {
            return openPlaylist(list, mode: mode, maxHeight: maxHeight, origin: origin, title: title, names: names ?? [:])
        }
        // Пост Threads: сначала достать из него прямые ссылки на видео (yt-dlp Threads не знает).
        if ThreadsLink.isThreads(rawURL) {
            Task { @MainActor in
                do {
                    for video in try await ThreadsLink.videos(rawURL) {
                        self.download(url: video.url, mode: mode, maxHeight: maxHeight, title: title ?? video.title,
                                      page: page ?? rawURL, origin: origin)
                    }
                } catch {
                    self.alert = Failure.system(error)
                }
            }
            return
        }
        let url = vimeoPlayerURL(rawURL) ?? vkVideoURL(rawURL) ?? rawURL
        let d = UserDefaults.standard
        let savedMode = Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .video
        let savedQuality = Quality(rawValue: d.integer(forKey: "quality")) ?? .best
        let folder = chosenFolder ?? d.string(forKey: "folder") ?? NSHomeDirectory() + "/Downloads"
        add(url: url, arguments: buildArguments(
            mode: mode ?? savedMode,
            maxHeight: maxHeight ?? (savedQuality == .best ? nil : savedQuality.rawValue),
            compatible: d.bool(forKey: "compatible"), subtitles: d.bool(forKey: "subtitles"),
            nameStyle: NameStyle(rawValue: d.string(forKey: "nameStyle") ?? "") ?? .title, folder: folder, url: url,
            title: title, prefix: prefix),
            page: page, origin: origin, displayTitle: displayTitle ?? title)  // название от расширения — сразу в строку
    }

    /// displayTitle — что показать в строке, пока yt-dlp не сообщил название (ролик плейлиста в очереди).
    func add(url: String, arguments: [String], page: String? = nil, origin: String? = nil, displayTitle: String? = nil) {
        guard let ytdlp = Tools.find("yt-dlp") else {
            alert = "Не найден yt-dlp. Установите его в «Компонентах» внизу окна."
            return
        }
        // Две одновременные загрузки одного ролика пишут в одни и те же файлы и портят результат.
        if let paused = jobs.first(where: { $0.state == .paused && $0.arguments == arguments }) { return paused.resume() }
        guard !jobs.contains(where: { $0.isRunning && $0.arguments == arguments }) else { return }
        let free = DownloadQueue.hasSlot
        let job = DownloadJob(url: url, arguments: arguments, page: page, origin: origin)
        if let displayTitle { job.title = displayTitle }
        if !free { job.enqueue() }
        jobs.insert(job, at: 0)
        save()
        Stats.send("download_start", job.statProps)
        if free { job.start(ytdlp: ytdlp) } else if displayTitle == nil { fetchTitle(job, ytdlp: ytdlp) }
        DockProgress.shared.start()
    }

    /// Названия по одному: пачка ссылок в очередь не должна разом дёргать сайт (YouTube принимает за робота).
    private static let titleQueue = DispatchQueue(label: "downmax.titles", qos: .utility)

    /// Название ролика в очереди: yt-dlp сообщает его только при старте, а до того в строке была бы ссылка.
    /// Спрашиваем заранее, без скачивания; не вышло — остаётся ссылка, название придёт при старте.
    private func fetchTitle(_ job: DownloadJob, ytdlp: String) {
        let url = job.url
        Self.titleQueue.async {
            // уже стартовала или название есть — не спрашиваем (состояние читаем в главном потоке)
            guard DispatchQueue.main.sync(execute: { job.state == .queued && job.title == url }) else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ytdlp)
            p.arguments = ["--skip-download", "--no-playlist", "--no-warnings", "--print", "%(title)s", "--", url]
            p.environment = Tools.environment
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let title = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard p.terminationStatus == 0, !title.isEmpty, title != "NA" else { return }
            DispatchQueue.main.async {
                if job.title == url { job.title = title; self.save() }
            }
        }
    }

    func downloadGallery(title: String, items: [GalleryItem], page: String? = nil, origin: String? = nil) {
        guard !items.isEmpty else { return }
        let base = UserDefaults.standard.string(forKey: "folder") ?? NSHomeDirectory() + "/Downloads"
        let name = sanitizeFilename(title)
        let arguments = ["gallery", name] + items.map(\.u)
        guard !jobs.contains(where: { $0.isRunning && $0.arguments == arguments }) else { return }
        let target = items.count == 1
            ? Self.uniquePath(base + "/" + name, ext: items[0].k)
            : Self.uniquePath(base + "/" + name, ext: nil)
        let free = DownloadQueue.hasSlot
        let job = DownloadJob(gallery: items, target: target, title: name, arguments: arguments, page: page, origin: origin)
        if !free { job.enqueue() }
        jobs.insert(job, at: 0)
        save()
        Stats.send("download_start", job.statProps)
        if free { job.startGallery() }
        DockProgress.shared.start()
    }

    /// «Имя.jpg», а если такое уже есть — «Имя (2).jpg»; для папок так же без расширения.
    static func uniquePath(_ base: String, ext: String?) -> String {
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
        // Ссылка на пост Threads (загрузка из версии, где их отдавали прямо в yt-dlp) — открыть пост заново.
        if ThreadsLink.isThreads(job.url) {
            remove(job)
            return download(url: job.url)
        }
        job.resume()
    }

    /// Готовый файл удалили или перенесли мимо приложения (Finder) — строка показывает «Файл удалён», кнопки «Открыть»
    /// и «Показать в Finder» пропадают. Вернули на место (из Корзины) — всё обратно.
    func checkFiles() {
        let fm = FileManager.default
        var changed = false
        for job in jobs where job.state == .done {
            guard let path = job.filePath else {
                // карусель — папка или файл по своему пути
                if let target = job.galleryTarget, job.fileDeleted == fm.fileExists(atPath: target) {
                    job.fileDeleted.toggle(); changed = true
                }
                continue
            }
            if fm.fileExists(atPath: path) {
                if job.fileDeleted { job.fileDeleted = false; changed = true }
                if job.fileBookmark == nil { job.fileBookmark = FileTracking.bookmark(path); changed = true }
            } else if let found = FileTracking.find(path, bookmark: job.fileBookmark) {
                job.filePath = found
                job.fileBookmark = FileTracking.bookmark(found)
                job.fileDeleted = false
                changed = true
            } else if !job.fileDeleted {
                job.fileDeleted = true
                changed = true
            }
        }
        if changed { save() }
    }

    /// Убрать из списка; недокачанное (если было) удаляется. Готовый файл остаётся.
    func remove(_ job: DownloadJob) {
        TempFiles.remove(TempFiles.folder(for: job.id))
        jobs.removeAll { $0.id == job.id }
        save()
    }

    /// Крестик у незавершённой загрузки — как у торрентов: спросить, затем остановить и убрать.
    func cancel(_ job: DownloadJob) {
        guard Ask.run("Отменить загрузку «\(job.title)»?", "Недокачанное удалится.",
                      buttons: ["Отменить загрузку", "Не отменять"]) == 0 else { return }
        job.cancel()
        remove(job)
    }

    func clearFinished() {
        jobs.filter { [.done, .failed, .cancelled].contains($0.state) }.forEach(remove)
    }
}

/// Элемент карусели: прямая ссылка и расширение файла (jpg, mp4…).
struct GalleryItem: Codable, Equatable {
    let u: String
    let k: String
}

// MARK: - Ссылки downmax:// от расширения Chrome

struct IncomingRequest {
    let url: String
    let mode: Mode?
    let maxHeight: Int?
    let title: String?
    var gallery: [GalleryItem]? = nil
    /// Страница, откуда взято (пост Threads, урок GetCourse), когда `url` — временная ссылка на сам файл.
    var page: String? = nil
    /// Откуда пришла (для статистики): chrome, safari, другое приложение.
    var origin: String = "other"
    /// Названия роликов плейлиста со страницы (VK отдаёт список без них): id ролика «-1_2» → название.
    var names: [String: String]? = nil
}

final class Inbox: ObservableObject {
    static let shared = Inbox()
    /// Ссылка, которую уже получали недавно: приложение спрашивает, качать ли её снова.
    @Published var repeated: IncomingRequest? {
        didSet {
            guard let r = repeated else { return }
            DispatchQueue.main.async {
                self.repeated = nil
                let what = r.gallery != nil ? (r.title ?? "") : r.url
                if Ask.run("Эту ссылку уже скачивали несколько минут назад", what, buttons: ["Скачать ещё раз", "Не нужно"]) == 0 {
                    self.start(r)
                }
            }
        }
    }

    private static let recentKey = "recentLinks"
    private static let recentWindow: TimeInterval = 10 * 60
    private static let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/DownMax.log")
    /// videoloader:// — прежнее имя приложения: так шлют ссылки расширения, поставленные до версии 2.0.
    private static let schemes: Set<String> = ["downmax", "videoloader"]

    /// downmax://download?url=<ссылка>&mode=video|m4a|mp3&quality=<высота, например 1080>&title=<имя файла>
    func receive(_ link: URL, from sender: String) {
        if link.scheme?.lowercased() == "magnet" {
            log("торрент", link, sender)
            TorrentManager.shared.open(magnet: link.absoluteString, origin: Self.origin(sender))
            return
        }
        if link.scheme == "downmax", let browser = Browser.allCases.first(where: { $0.bundleID == sender }) {
            Setup.shared.extensionWorks(in: browser)
        }
        // downmax://installed — страничка расширения сразу после установки: скачивать нечего
        if link.host == "installed" {
            log("расширение установлено", link, sender)
            return
        }
        // downmax://gallery?title=<имя>&items=<JSON [{u, k}]> — карусель из окошка расширения
        if Self.schemes.contains(link.scheme ?? ""), link.host == "gallery",
           let q = URLComponents(string: link.absoluteString.replacingOccurrences(of: "+", with: "%20"))?.queryItems,
           let json = q.first(where: { $0.name == "items" })?.value,
           let items = try? JSONDecoder().decode([GalleryItem].self, from: Data(json.utf8)), !items.isEmpty {
            let title = q.first(where: { $0.name == "title" })?.value ?? "Карусель"
            return accept(IncomingRequest(url: "gallery", mode: nil, maxHeight: nil, title: title, gallery: items,
                                          page: Self.webLink(q.first(where: { $0.name == "page" })?.value),
                                          origin: Self.origin(sender)),
                          link: link, sender: sender)
        }
        guard Self.schemes.contains(link.scheme ?? ""),
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
        let names = items.first(where: { $0.name == "names" })?.value
            .flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
        let request = IncomingRequest(url: target, mode: mode, maxHeight: height, title: title,
                                      page: Self.webLink(items.first(where: { $0.name == "page" })?.value),
                                      origin: Self.origin(sender), names: names)
        accept(request, link: link, sender: sender)
    }

    /// Кто прислал ссылку — для статистики: расширение в Chrome, в Safari или что-то ещё.
    private static func origin(_ sender: String) -> String {
        if Browser.allCases.contains(where: { $0.bundleID == sender }) { return "chrome" }
        return sender.lowercased().contains("safari") ? "safari" : "other"
    }

    /// Только ссылки http(s): страница показывается в подробностях и открывается щелчком.
    private static func webLink(_ s: String?) -> String? {
        guard let s, let u = URL(string: s), ["http", "https"].contains(u.scheme ?? ""), u.host != nil else { return nil }
        return s
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

    private func start(_ r: IncomingRequest) {
        if let items = r.gallery {
            DownloadManager.shared.downloadGallery(title: r.title ?? "Карусель", items: items, page: r.page, origin: r.origin)
        } else {
            DownloadManager.shared.download(url: r.url, mode: r.mode, maxHeight: r.maxHeight, title: r.title, page: r.page,
                                            names: r.names, origin: r.origin)
        }
    }

    func log(_ action: String, _ link: URL, _ sender: String) {
        let text = link.absoluteString
        note("\(sender)  \(action)  \(text.count > 300 ? text.prefix(300) + "…" : Substring(text))")
    }

    /// Строка в журнал со временем (не только входящие ссылки: например, автообновление yt-dlp).
    func note(_ text: String) {
        let time = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withFullTime])
        let line = "\(time)  \(text)\n"
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
    @ObservedObject private var torrents = TorrentManager.shared
    @ObservedObject private var updater = Updater.shared
    @AppStorage("folder") private var folder = NSHomeDirectory() + "/Downloads"
    @AppStorage("mode") private var modeRaw = Mode.video.rawValue
    @AppStorage("compatible") private var compatible = false
    @AppStorage("subtitles") private var subtitles = false
    @AppStorage("nameStyle") private var nameStyleRaw = NameStyle.title.rawValue
    private var nameStyle: NameStyle { NameStyle(rawValue: nameStyleRaw) ?? .title }
    private var folderName: String { (folder as NSString).lastPathComponent }
    @AppStorage("quality") private var qualityRaw = Quality.best.rawValue
    @State private var url = ""
    @State private var dropTargeted = false
    /// Идёт проверка ссылки из поля: файл это или страница с видео.
    @State private var checking = false
    @FocusState private var fieldFocused: Bool
    @State private var fieldHovered = false
    /// Строка, по которой щёлкнули: под списком — панель с подробностями о ней.
    @State private var selectedID: UUID?
    /// Строка, на которой сейчас зажата мышь: темнеет сразу, до того как станет ясно, одинарный это щелчок или двойной.
    @State private var pressedID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Отмеченные галочками — для удаления нескольких сразу.
    @State private var checked: Set<UUID> = []
    @AppStorage("listSort") private var sortRaw = ListSort.newest.rawValue
    @AppStorage("listStatus") private var statusRaw = StatusFilter.all.rawValue
    @AppStorage("listSource") private var sourceFilter = ""
    @State private var rowsHeight: CGFloat = 0
    private static let minDropHeight: CGFloat = 150
    /// Между строками списка; от панели над списком — 10 (на ступень больше: панель — своя группа).
    private static let rowGap: CGFloat = 8

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .video }
    private var quality: Quality { Quality(rawValue: qualityRaw) ?? .best }
    private var urlIsValid: Bool { !links.isEmpty }
    /// Все ссылки из поля: через пробел, с новой строки или внутри текста («Смотри: https://…»), без повторов.
    private var links: [String] { LinkRouter.allLinks(in: url) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
            // Две группы: «новая загрузка» (поле, режим, папка) и «список» (панель, строки, подробности)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    // Своя рамка вместо системной синей: 1 px, розовая, пока в поле курсор.
                    TextField("Ссылка на видео, файл или magnet-ссылка", text: $url)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                        .focusEffectDisabled()
                        .onSubmit(start)
                        .padding(.leading, 14)
                        .padding(.trailing, 40)  // место под значок справа (поле 28 + 12)
                        .padding(.bottom, 2)  // на 1 pt выше середины — оптический центр строки
                        .frame(height: Metrics.large)
                        // Справа в поле: пустое — открыть торрент-файл, с текстом — стереть. Значок — на 14 от края,
                        // как текст слева; поле значка 28 в плашке 32.
                        .overlay(alignment: .trailing) {
                            Group {
                                if url.isEmpty {
                                    // скрепка высокая и узкая: 12 pt — не выше строчных букв текста; край — на 14 от края поля, как текст слева
                                    IconButton("paperclip", "Открыть торрент-файл (⌘O)", rotation: -25, size: 12,
                                               action: torrents.chooseTorrentFile)
                                        .padding(.trailing, 2)
                                } else {
                                    IconButton("xmark.circle.fill", "Стереть") { url = ""; fieldFocused = true }
                                }
                            }
                            .padding(.trailing, 2)
                        }
                        // щелчок в любом месте плашки ставит курсор: сам текст поля высотой 16, а плашка 32
                        .background(RoundedRectangle(cornerRadius: Metrics.radius(Metrics.large)).fill(Color.field)
                            .onTapGesture { fieldFocused = true })
                        .fieldBorder(focused: fieldFocused, hovering: fieldHovered, cornerRadius: Metrics.radius(Metrics.large))  // как кнопки рядом
                        .onHover { fieldHovered = $0 }
                        .animation(.easeOut(duration: 0.12), value: fieldFocused)
                        .animation(.easeOut(duration: 0.1), value: fieldHovered)
                    Button(action: start) {
                        if checking { ProgressView().controlSize(.small).frame(width: 52) } else {
                            Text(links.count > 1 ? "Скачать · \(links.count)" : "Скачать")  // несколько ссылок — видно сколько
                        }
                    }
                        .controlSize(.large)
                        .buttonStyle(.brandFill)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!urlIsValid || checking)
                }

                // Строка настроек — всё одного вида: вкладки и серые кнопки 28 с меню, как панель над списком.
                HStack(spacing: 8) {
                    // Выпадающим списком, как «Качество» и «Имя файла» (решение пользователя; раньше — вкладки).
                    MenuButton(entries: modeEntries) {
                        HStack(spacing: 6) {
                            Text("Формат:").foregroundStyle(.secondary)
                            Text(mode.rawValue).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .fixedSize()
                    .help("Скачивать видео или только звук")
                    .accessibilityLabel("Формат: \(mode.rawValue)")

                    // «Без перекодирования» — пунктом в этом же меню: это тоже про качество.
                    // Для звука кнопка серая, а не пропадает: строка не прыгает (решение пользователя).
                    MenuButton(entries: qualityEntries) {
                        HStack(spacing: 6) {
                            Text("Качество:").foregroundStyle(mode == .video ? .secondary : .tertiary)
                            Text(quality.title + (compatible ? " · H.264" : "") + (subtitles ? " · Субтитры" : "")).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .disabled(mode != .video)
                    .help(mode != .video ? "Для звука DownMax берёт лучшую дорожку"
                          : compatible ? "Без перекодирования: файл готов быстрее, но обычно не выше 1080p"
                                       : "Лучшее качество. Если нужно, DownMax перекодирует видео, чтобы оно открывалось в QuickTime")
                    .accessibilityLabel("Качество видео: \(quality.title)")
                    // Своей кнопкой, а не пунктом в меню папки: там её не находили (решение пользователя).
                    MenuButton(entries: nameEntries) {
                        HStack(spacing: 6) {
                            Text("Имя:").foregroundStyle(.secondary)
                            Text(nameStyle.menuTitle).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .fixedSize()
                    .help("Как называть файлы: только название, с автором или с датой публикации")
                    .accessibilityLabel("Имя файла: \(nameStyle.menuTitle)")
                    Spacer(minLength: 8)
                    // Папка для следующих загрузок — тихой строкой (меняют редко, не спорит с кнопками): серый путь,
                    // под курсором — розовый, как ссылка. В меню — полный путь, «Изменить…», «Показать в Finder».
                    MenuButton(entries: folderEntries) {
                        HStack(spacing: 4) {
                            // Полный путь, без «~» (решение пользователя); не помещается — имя папки, затем значок и имя.
                            ViewThatFits(in: .horizontal) {
                                Text("Сохранять в \(folder)").lineLimit(1).fixedSize()
                                Text("Сохранять в \(folderName)").lineLimit(1).fixedSize()
                                HStack(spacing: 4) {
                                    Image(systemName: "folder").font(.system(size: 11, weight: .medium))
                                    Text(folderName).lineLimit(1).truncationMode(.middle)
                                }
                            }
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .buttonStyle(.quietPill)
                    .help("Куда сохранять: \(folder)")
                    .accessibilityLabel("Папка загрузки: \(folder)")
                    .layoutPriority(-1)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                let hasAny = !(manager.jobs.isEmpty && torrents.torrents.isEmpty)
                let items = ListFilter.items(videos: manager.jobs, torrents: torrents.torrents,
                                             sort: ListSort(rawValue: sortRaw) ?? .newest,
                                             status: StatusFilter(rawValue: statusRaw) ?? .all, source: sourceFilter)
                let isEmpty = items.isEmpty
                if hasAny {  // у пустого списка своя рамка — панель ни к чему
                    ListToolbar(items: items, checkedItems: checkedItems, checked: $checked, sortRaw: $sortRaw,
                                statusRaw: $statusRaw, source: $sourceFilter, delete: deleteChecked)
                    if isEmpty {
                        Text("Таких загрузок нет").font(.callout).foregroundStyle(.secondary)
                    }
                }

                // Загрузки сверху, под ними — рамка для торрент-файлов на всё оставшееся место
                // (не ниже minDropHeight: при длинном списке она уезжает вниз вместе с прокруткой).
                GeometryReader { outer in
                    ScrollView {
                        VStack(spacing: Self.rowGap) {
                            if !isEmpty {
                                LazyVStack(spacing: Self.rowGap) {
                                    ForEach(items) { item in
                                        switch item {
                                        case .torrent(let job):
                                            selectable(TorrentRow(job: job, manager: torrents, checked: checkBinding(job.id)), job.id,
                                                   reveal: job.filesDeleted ? job.record.folder : job.target)
                                        case .video(let job):
                                            selectable(JobRow(job: job, manager: manager, checked: checkBinding(job.id)), job.id,
                                                   reveal: (job.fileDeleted ? nil : job.filePath ?? job.galleryTarget) ?? job.folder)
                                        }
                                    }
                                }
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                                .animation(motion, value: items.map(\.id))  // новые и удалённые строки — плавно
                            }
                            // При открытых подробностях рамку, которой не хватает места, не показываем:
                            // иначе край прокрутки режет её пополам. Бросить торрент можно на всё окно.
                            if showDrop(outer.size.height, isEmpty) {
                                dropZone
                                    .frame(height: max(Self.minDropHeight, outer.size.height - (isEmpty ? 0 : rowsHeight + Self.rowGap)))
                            }
                        }
                        // щелчок мимо строк (между ними, по рамке внизу) снимает выделение; щелчок по строке — её жест
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = nil; fieldFocused = false }  // прокрутка забирает щелчок — снимаем фокус тут
                    }
                    .scrollDisabled(isEmpty || rowsHeight + (showDrop(outer.size.height, isEmpty) ? Self.rowGap + Self.minDropHeight : 0) <= outer.size.height)
                    .thinScrollIndicator()
                }

                if let id = selectedID {
                    DetailsPanel(id: id, manager: manager, torrents: torrents) { selectedID = nil }
                        .padding(.top, 6)  // 16 от списка: панель — не ещё одна строка
                        // выезжает снизу и уходит туда же; при «Уменьшить движение» — только проявляется
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 24)))
                }
            }
            .animation(motion, value: selectedID)
            }
            .padding(20)

            footer
        }
        // 940 — влезают все выпадающие списки с самыми длинными подписями («Качество: Максимальное · H.264 · Субтитры»,
        // «Имя: Автор — Название») и панель над списком с «Пауза», «Продолжить», «Удалить…». Новая кнопка
        // в строке — пересчитать.
        .frame(minWidth: 940, minHeight: 760)
        .buttonStyle(.gray)  // у кнопок без своего стиля — наведение (у системных его нет)
        // щелчок по пустому месту окна убирает курсор из поля ссылки и снимает выделение строки
        .background(Color.clear.contentShape(Rectangle()).onTapGesture {
            fieldFocused = false
            selectedID = nil
        })
        // загрузку убрали из списка (крестик, меню, отмеченные) — снять с неё выбор и галочку
        .onChange(of: listIDs) { _, ids in dropMissing(ids) }
        // и пока окно открыто: файл можно удалить в Finder, не уходя из DownMax (окна рядом)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in checkFiles() }
        .onAppear {
            checkFiles()
            pasteIfEmpty()
            setup.refresh(openIfMissing: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if setup.checked && setup.busy == nil { setup.refresh() }
            checkFiles()  // вернулись из Finder — файлы могли удалить руками
            updater.checkDaily()  // окно может быть открыто днями
        }
        .sheet(isPresented: $setup.showSheet) { SetupSheet(setup: setup).presentationBackground(Color.surface) }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension.lowercased() == "torrent" else { return }
                    DispatchQueue.main.async { torrents.open(torrentFile: url) }
                }
            }
            return true
        }
        .background {
            // Второй .sheet на том же виде SwiftUI не показывает — вешаем на фон.
            Color.clear.sheet(item: $torrents.pending) {
                NewTorrentSheet(pending: $0, manager: torrents).presentationBackground(Color.surface)
            }
            .background {
                Color.clear.sheet(item: $manager.pendingPlaylist) {
                    PlaylistSheet(pending: $0, manager: manager).presentationBackground(Color.surface)
                }
            }
        }
    }

    /// Нижняя строка — полосой другого цвета во всю ширину окна: состояние, скорость, обновление, отзыв.
    private var footer: some View {
        HStack {
            StatusButton(setup: setup)
            TransferTotals(manager: manager, torrents: torrents).padding(.leading, 8)
            Spacer()
            if setup.safari == .disabled {
                Text("Расширение для Safari выключено").font(.callout).foregroundStyle(.secondary)
                Button("Включить", action: SafariExtension.openSettings)
                    .controlSize(.small)
                    .help("Откроет Safari → Настройки → Расширения: поставьте галочку у «DownMax»")
            }
            if setup.checked && setup.extensionMissing {
                Button("Расширение для браузера…") { setup.showSheet = true }
                    .buttonStyle(.brandLink)
                    .font(.callout)
            }
            UpdateBar(updater: updater)
            Button { Feedback.showWindow() } label: { Label("Оценить", systemImage: "star") }
                .buttonStyle(.quiet)
                .background(PopoverAnchor(id: "rate"))
                .padding(.leading, 16)
            DonateButton()
                .background(PopoverAnchor(id: "support"))
                .padding(.leading, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.footer)
        .overlay(alignment: .top) { Rectangle().fill(Color.hairline).frame(height: 1) }
    }

    private func checkFiles() {
        manager.checkFiles()
        torrents.checkFiles()
    }

    private var listIDs: [UUID] {
        let videos: [UUID] = manager.jobs.map(\.id)
        let torrentIDs: [UUID] = torrents.torrents.map(\.id)
        return videos + torrentIDs
    }

    private func dropMissing(_ ids: [UUID]) {
        if let id = selectedID, !ids.contains(id) { selectedID = nil }
        checked.formIntersection(ids)
    }

    private func checkBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { checked.contains(id) },
                set: { if $0 { checked.insert(id) } else { checked.remove(id) } })
    }

    private func deleteChecked() {
        DispatchQueue.main.async(execute: deleteCheckedNow)  // вопрос — после щелчка, см. IconButton
    }

    /// Отмеченные галочками — и скрытые фильтром тоже.
    private var checkedItems: [ListItem] {
        guard !checked.isEmpty else { return [] }
        return ListFilter.items(videos: manager.jobs, torrents: torrents.torrents, sort: .newest, status: .all, source: "")
            .filter { checked.contains($0.id) }
    }

    private func deleteCheckedNow() {
        guard BulkDelete.run(checkedItems) else { return }
        if let id = selectedID, checked.contains(id) { selectedID = nil }
        checked = []
    }

    /// Щелчок по строке выбирает её (розовая рамка, панель подробностей), повторный — снимает выбор.
    /// Двойной щелчок только открывает Finder с выделенным файлом (у недокачанного — папку загрузки), без панели.
    private func selectable<Row: View>(_ row: Row, _ id: UUID, reveal: String?) -> some View {
        row
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Color.brand, lineWidth: 1.5)
                .opacity(selectedID == id ? 1 : 0))
            // нажатие видно сразу: одинарный щелчок срабатывает с задержкой (ждёт, не будет ли двойного) — так задумано
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .fill(Color.black.opacity(pressedID == id ? 0.12 : 0))
                .allowsHitTesting(false))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if let reveal { Finder.reveal(reveal) } }
            .onTapGesture { selectedID = selectedID == id ? nil : id; fieldFocused = false }
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if pressedID != id { pressedID = id } }
                .onEnded { _ in pressedID = nil })
            .transition(.opacity)
    }

    /// Движение в окне — пружина без отскока (как у Apple по умолчанию); при «Уменьшить движение» — короткое проявление.
    private var motion: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1)
    }

    private func showDrop(_ height: CGFloat, _ isEmpty: Bool) -> Bool {
        selectedID == nil || isEmpty || rowsHeight + Self.rowGap + Self.minDropHeight <= height
    }

    /// Пунктирная рамка — место, куда бросать торрент-файл; при перетаскивании подсвечивается.
    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Вставьте ссылку и нажмите «Скачать»").foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text("Торрент-файл перетащите сюда или").foregroundStyle(.secondary)
                Button("выберите на диске…", action: torrents.chooseTorrentFile).buttonStyle(.brandLink)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .fill(dropTargeted ? AnyShapeStyle(Color.brand.opacity(0.08)) : AnyShapeStyle(.clear))
            RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .strokeBorder(dropTargeted ? AnyShapeStyle(Color.brand) : AnyShapeStyle(.tertiary),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }

    /// Ссылки уходят по очереди: у каждой сначала проверяется, файл это или страница (FileLink.detect).
    private func start() {
        let all = links
        guard !all.isEmpty, !checking else { return }
        let mode = mode
        url = ""
        checking = true
        Task { @MainActor in
            for (i, link) in all.enumerated() {
                if await !LinkRouter.submit(link, mode: mode, origin: "field") {
                    url = all[i...].joined(separator: " ")  // не хватает компонентов — «Компоненты» открыты, ссылки вернуть
                    break
                }
            }
            checking = false
        }
    }

    private func pasteIfEmpty() {
        guard url.isEmpty, let s = NSPasteboard.general.string(forType: .string) else { return }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("youtube.com/") || t.contains("youtu.be/") || t.lowercased().hasPrefix("magnet:?") { url = t }
    }

    private func qualityEntries() -> [MenuEntry] {
        Quality.allCases.map { q in MenuEntry(title: q.title, checked: q == quality) { qualityRaw = q.rawValue } }
            + [.separator,
               MenuEntry(title: "Без перекодирования (быстрее, до 1080p)", checked: compatible) { compatible.toggle() },
               MenuEntry(title: "Субтитры (русские и английские)", checked: subtitles) { subtitles.toggle() }]
    }

    private func folderEntries() -> [MenuEntry] {
        [MenuEntry(title: folder),  // без действия — серой строкой, чтобы был виден полный путь
         .separator,
         MenuEntry(title: "Изменить папку…") { chooseFolder() },
         MenuEntry(title: "Показать в Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }]
    }

    private func modeEntries() -> [MenuEntry] {
        Mode.allCases.map { m in MenuEntry(title: m.rawValue, checked: m == mode) { modeRaw = m.rawValue } }
    }

    private func nameEntries() -> [MenuEntry] {
        NameStyle.allCases.map { style in
            MenuEntry(title: style.menuTitle, checked: style == nameStyle) { nameStyleRaw = style.rawValue }
        }
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
    @Binding var checked: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $checked).toggleStyle(.brandCheckbox).labelsHidden()
            icon.font(.title2).frame(width: 28)

            // между заголовком, полосой и состоянием — 8: видно ~10 до плашки метки и ~11 до полосы, больше
            // межстрочного воздуха заголовка (~7) — не влипает
            VStack(alignment: .leading, spacing: 8) {
                Text(job.title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                switch job.state {
                case .processing where job.convertProgress != nil:
                    LoadBar(value: job.convertProgress ?? 0)
                case .starting, .processing:
                    LoadBar(value: job.progress, waiting: true)  // подключается или склеивает — хода нет, есть блик
                case .downloading:
                    LoadBar(value: job.progress)
                case .paused, .queued:
                    LoadBar(value: job.progress, dimmed: true)
                default:
                    EmptyView()
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    SourceTag(name: job.sourceName)
                    Text(job.state == .done ? job.doneLine : job.detail)
                        .font(.subheadline)  // 11: не мельче метки источника
                        .foregroundStyle(job.state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 0) {
                if job.isConverting {
                    iconButton("xmark", "Остановить перекодирование (файл останется как есть)", job.cancel)
                } else if job.isRunning || job.state == .paused || job.state == .queued {
                    if job.canPause { iconButton("pause", "Пауза", job.pause) }
                    if job.state == .paused { iconButton("play", "Продолжить", job.resume) }
                    if job.state == .queued { iconButton("play", "Начать сейчас, не дожидаясь очереди", job.resume) }
                    iconButton("xmark", "Отменить загрузку…") { manager.cancel(job) }
                } else {
                    if hasFile {
                        iconButton("play", "Открыть", openFile)
                        iconButton("folder", "Открыть папку с файлом", revealFile)
                        iconButton("trash", "Удалить файл с диска…", deleteFile)
                    }
                    if job.state == .failed || job.state == .cancelled {
                        iconButton("arrow.clockwise", "Повторить") { manager.retry(job) }
                    }
                    iconButton("xmark", "Удалить загрузку…") { BulkDelete.run([.video(job)]) }
                }
            }
            .padding(.trailing, -6)  // значок, а не поле 28, — на 14 от края, как галочка слева
        }
        .padding(Metrics.cardPadding)
        .rowCard()
        .contextMenu {
            if job.isConverting {
                Button("Остановить перекодирование", action: job.cancel)
            } else if job.isRunning || job.state == .paused || job.state == .queued {
                if job.canPause { Button("Пауза", action: job.pause) }
                if job.state == .paused { Button("Продолжить", action: job.resume) }
                if job.state == .queued { Button("Начать сейчас", action: job.resume) }
                Button("Отменить загрузку…") { manager.cancel(job) }
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
                Button("Удалить загрузку…") { BulkDelete.run([.video(job)]) }
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
        guard Ask.run("Удалить файл с диска?", "«\(url.lastPathComponent)» будет перемещён в Корзину.",
                      buttons: ["В Корзину", "Отмена"]) == 0 else { return }
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
        case .starting, .downloading: Image(systemName: "arrow.down.circle").foregroundStyle(Color.brand)
        case .paused: Image(systemName: "pause.circle").foregroundStyle(.secondary)
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .processing: Image(systemName: "gearshape.circle").foregroundStyle(Color.brand)
        // файла на диске нет — галочка серая: загрузка была, но «всё готово» уже неправда
        case .done: Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(job.fileDeleted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.green))
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        IconButton(symbol, help, action: action)
    }
}

// MARK: - Состояние компонентов

struct StatusButton: View {
    @ObservedObject var setup: Setup
    @State private var hovering = false

    var body: some View {
        Button { setup.showSheet = true } label: {
            HStack(spacing: 6) {
                if setup.busy != nil || !setup.checked {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                Text(text).foregroundStyle(setup.allGood && !hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if !setup.allGood && setup.busy == nil && setup.checked {
                    Text("Установить…").foregroundStyle(Color.brand)
                }
            }
            .font(.callout)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("yt-dlp, ffmpeg, deno и aria2: состояние, установка, обновление")
    }

    private var color: Color { setup.allGood ? .green : (setup.canDownload ? .orange : .red) }

    private var text: String {
        if let busy = setup.busy {
            return busy + (setup.progress.map { " · \(Int($0 * 100))%" } ?? "…")
        }
        if !setup.checked { return "Проверяю компоненты…" }
        if setup.allGood { return "Всё готово" }  // версии — в «Компонентах» по щелчку
        return "Нужно установить: " + setup.missing.map(\.id).joined(separator: ", ")
    }
}

struct SetupSheet: View {
    @ObservedObject var setup: Setup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Компоненты").font(.title2.bold())
                Text("DownMax качает видео и торренты этими программами. Чего не хватает, можно поставить здесь.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)  // 20 до карточек: заголовок — своя группа

            VStack(spacing: 0) {
                ForEach(setup.components) { c in
                    row(ok: c.installed, name: c.id, detail: c.purpose,
                        status: c.installed ? (c.version ?? "установлен") : "не установлен")
                    if c.id != setup.components.last?.id { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Color.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Color.hairline))

            if setup.components.first?.installed == true { YtdlpUpdateRow(setup: setup) }

            VStack(spacing: 0) {
                if setup.browsers.isEmpty && setup.safari == .absent {
                    Text("Google Chrome нет в «Программах», расширение ставить некуда.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
                if setup.safari != .absent {
                    HStack(spacing: 10) {
                        Image(systemName: setup.safari == .enabled ? "checkmark.circle.fill" : "puzzlepiece.extension.fill")
                            .foregroundStyle(setup.safari == .enabled ? .green : .orange)
                            .font(.title3)
                            .frame(width: 22)  // одна колонка значков во всех карточках «Компонентов»
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Расширение для Safari").font(.headline)
                            Text("включается в настройках Safari")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(setup.safari == .enabled ? "включено" : "выключено")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button(setup.safari == .enabled ? "Настройки Safari" : "Включить", action: SafariExtension.openSettings)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    if !setup.browsers.isEmpty { Divider() }
                }
                ForEach(Array(setup.browsers.enumerated()), id: \.element.id) { i, state in
                    if i > 0 { Divider() }
                    HStack(spacing: 10) {
                        Image(systemName: state.extensionInstalled ? "checkmark.circle.fill" : "puzzlepiece.extension.fill")
                            .foregroundStyle(state.extensionInstalled ? .green : .orange)
                            .font(.title3)
                            .frame(width: 22)  // одна колонка значков во всех карточках «Компонентов»
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Color.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Color.hairline))

            TorrentHandlerRow()
            RemoteRow()

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
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Color.orange.opacity(0.12)))
            }

            if let progress = setup.progress {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress).tint(.brand)
                    Text(setup.busy ?? "").font(.callout).foregroundStyle(.secondary)
                }
            } else if !setup.missing.isEmpty && setup.busy == nil && !setup.failed {
                note("arrow.down.circle", "DownMax скачает недостающее сам, около \(setup.downloadSize) МБ. Пароль не нужен.")
            }

            if !setup.log.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(setup.log)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(setup.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(height: 120)
                    .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Color.field))
                    .onChange(of: setup.log) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
            }

            HStack(spacing: 8) {
                Button("Проверить заново") { setup.refresh() }
                    .disabled(setup.busy != nil)
                Spacer()
                if let busy = setup.busy, setup.progress == nil {
                    ProgressView().controlSize(.small)
                    Text(busy + "…").foregroundStyle(.secondary)
                } else if !setup.missing.isEmpty && setup.busy == nil {
                    Button("Установить", action: setup.installMissing)
                        .buttonStyle(.brandFill)
                }
                Button(setup.allGood ? "Готово" : "Закрыть") { dismiss() }
                    .keyboardShortcut(setup.allGood ? .defaultAction : .cancelAction)
            }
            .controlSize(.large)
            .padding(.top, 8)  // 24 от содержимого: кнопки — отдельная группа
        }
        .padding(24)
        .frame(width: 600)
        .buttonStyle(.gray)
    }

    private func row(ok: Bool, name: String, detail: String, status: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
                .font(.title3)
                .frame(width: 22)  // одна колонка значков во всех карточках «Компонентов»
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(status)
                .font(.callout.monospacedDigit())
                .foregroundStyle(ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

    /// Значок без полосы — при запуске и когда загрузки закончились.
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
        let torrents = TorrentManager.shared.downloading
        guard !running.isEmpty || !torrents.isEmpty else {
            timer?.invalidate()
            timer = nil
            showIdle()
            MenuBar.shared.finished()
            // приложение в фоне — значок один раз подпрыгнет, что всё готово
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            return
        }
        // обработка (склейка, перекодирование) считается почти готовой загрузкой
        let values = running.map { job -> Double in
            switch job.state {
            case .downloading: return job.progress
            case .processing: return job.convertProgress ?? 1
            default: return 0
            }
        }
        + torrents.map(\.progress)
        view.progress = values.reduce(0, +) / Double(values.count)
        view.frame = NSRect(origin: .zero, size: tile.size)
        tile.contentView = view
        let count = running.count + torrents.count
        tile.badgeLabel = count > 1 ? String(count) : nil
        tile.display()
        MenuBar.shared.update(progress: view.progress ?? 0, count: count)
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    // Главное окно создаёт само приложение, а не SwiftUI-сцена: при запуске в фоне
    // (например, браузером по ссылке) SwiftUI окно не открывает, а открыть его из кода нельзя.
    private var window: NSWindow?

    /// Окно открыто — значок в Доке; закрыто — только в строке меню (MenuBar), загрузки идут дальше.
    func showMainWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            DockProgress.shared.showIdle()  // плитку Дока после смены режима рисуем заново
        }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 800),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "DownMax"
            w.backgroundColor = .surface  // свой серый вместо системного, в который macOS подмешивает обои
            w.titlebarAppearsTransparent = true  // заголовок — того же серого, что и окно
            let host = NSHostingController(rootView: ContentView())
            host.sizingOptions = [.minSize]  // SwiftUI задаёт только минимум, иначе сжимает окно до него
            w.contentViewController = host
            w.setContentSize(NSSize(width: 940, height: 800))
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("MainWindow")
            w.delegate = self
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // macOS сама ставит курсор в первое поле — розовая рамка горела бы без щелчка. Поле ждёт щелчка.
        DispatchQueue.main.async { self.window?.makeFirstResponder(nil) }
    }

    // Клик по значку в Доке, когда окно закрыто или свёрнуто.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // В тёмном режиме иконок macOS перекрашивает иконку из бандла; картинку, заданную так, Док рисует как есть.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)  // и для вопроса о переносе
        if AppMover.moveIfNeeded() { return }  // открыли из «Загрузок» — переезд в «Программы» и перезапуск
        Wizard.decideOnLaunch()  // до переноса настроек: по их следам видно, что DownMax уже был
        OldName.migrate()
        // Только тёмная тема (решение пользователя 2026-09-26: светлая не нравится), независимо от темы Mac.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Stats.start()
        MenuBar.shared.install()
        BrowserExtension.refreshIfInstalled()
        let unfinished = DownloadManager.shared.restore()
        TempFiles.removeAll(except: unfinished)
        DownloadManager.shared.resumeAfterLaunch()
        TorrentManager.shared.restore()
        Updater.shared.checkDaily()
        YtdlpAutoUpdate.start()
        TorrentHandler.claimOnce()
        TorrentWatcher.start()
        RemoteReceiver.shared.startIfEnabled()
        if Wizard.pending { Wizard.show(then: showMainWindow) } else { showMainWindow() }
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

    // Ссылки downmax:// принимаются своим обработчиком Apple Event, а не через SwiftUI:
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
        // После установки расширения — обратно к мастеру, если он открыт, а не главное окно поверх него
        if link.host == "installed" && Wizard.isOpen { Wizard.show() } else { showMainWindow() }
    }

    /// .torrent из Finder (двойной щелчок, «Открыть с помощью», перетаскивание на значок в Доке).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL && url.pathExtension.lowercased() == "torrent" {
            TorrentManager.shared.open(torrentFile: url)
        }
        showMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    // Выход во время загрузки ничего не теряет: и видео, и торренты продолжатся при следующем запуске.
    func applicationWillTerminate(_ notification: Notification) {
        let unfinished = Set(DownloadManager.shared.jobs.filter { $0.isRunning || $0.state == .paused }.map(\.id))
        DownloadManager.shared.stopAllForQuit()
        RunningProcesses.stopAll()
        TorrentManager.shared.stopAllForQuit()
        TempFiles.removeAll(except: unfinished)
        Updater.shared.installOnQuit()
    }
}

/// Галочка в меню DownMax. Своё состояние — чтобы галочка менялась сразу, без перезапуска меню.
private struct StatsToggle: View {
    @State private var on = Stats.enabled
    var body: some View {
        Toggle("Отправлять анонимную статистику", isOn: $on)
            .onChange(of: on) { _, value in Stats.enabled = value }
    }
}

@main
struct DownMaxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Главное окно — в AppDelegate.showMainWindow(); SwiftUI-сцене нужна хотя бы одна сцена.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {}  // без пустого пункта «Настройки…»
                CommandGroup(after: .appInfo) {
                    Button("Проверить обновления…") { Updater.shared.check(manual: true) }
                    Button("Помощник настройки…") { Wizard.show() }
                    Button("Оценить DownMax…") { Feedback.showWindow() }
                    Button("Поддержать DownMax ♥") { Donate.showWindow(from: "menu") }
                    Divider()
                    StatsToggle()
                }
                CommandGroup(replacing: .newItem) {
                    Button("Открыть торрент-файл…") { TorrentManager.shared.chooseTorrentFile() }
                        .keyboardShortcut("o")
                }
            }
    }
}
