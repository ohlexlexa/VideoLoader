import Foundation

// MARK: - Анонимная статистика

/// События уходят в функцию Yandex Cloud (код — stats/index.py), она пишет их в YDB, графики — в DataLens.
/// Ни ссылок, ни названий, ни путей, ни текста ошибок: только вид события, сайт из `Source.sites`, вид загрузки,
/// числа и случайный номер установки. События копятся в файле и уходят пачкой: без сети не теряются,
/// а если Яндекс не ответил — DownMax ничего не показывает и не ждёт.
enum Stats {
    static let endpoint = URL(string: "https://functions.yandexcloud.net/d4ejckuk94clco8dioh1")!

    /// Галочка «Отправлять анонимную статистику» в меню DownMax. Выключили — очередь стирается.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "statsEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "statsEnabled")
            if !newValue { queue.async { pending = []; save() } }
        }
    }

    private static let queue = DispatchQueue(label: "downmax.stats")
    private static let file = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/DownMax/stats.json")
    private static let limit = 1000   // событий в очереди, дальше старые выбрасываются
    private static let batch = 100    // событий в одном запросе (столько принимает функция)
    private static var pending: [[String: Any]] = {
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list
    }()
    private static var sending = false
    private static var flushScheduled = false

    /// Случайный номер установки: создаётся при первом запуске, ни с чем не связан.
    private static let install: String = UserDefaults.standard.string(forKey: "statsInstall") ?? {
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "statsInstall")
        return id
    }()

    private static let common: [String: Any] = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return ["app": Updater.shared.current,
                "os": "\(v.majorVersion).\(v.minorVersion)",
                "build": SafariExtension.isBundled ? "safari" : "release"]
    }()

    static func send(_ name: String, _ props: [String: Any] = [:]) {
        guard enabled else { return }
        _ = install
        var event = common.merging(props) { _, new in new }
        event["id"] = UUID().uuidString
        event["ts"] = Int(Date().timeIntervalSince1970)
        event["name"] = name
        queue.async {
            pending.append(event)
            if pending.count > limit { pending.removeFirst(pending.count - limit) }
            save()
            // несколько событий подряд (старт и готово у короткого ролика) — одной пачкой
            guard !flushScheduled else { return }
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + 10) { flushScheduled = false; flush() }
        }
    }

    /// При запуске: отправить то, что не ушло в прошлый раз.
    static func start() {
        guard enabled else { return }
        if UserDefaults.standard.string(forKey: "statsInstall") == nil { send("install") }
        queue.asyncAfter(deadline: .now() + 5) { flush() }
    }

    private static func save() {
        guard let data = try? JSONSerialization.data(withJSONObject: pending) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private static func flush() {
        guard enabled, !sending, !pending.isEmpty else { return }
        let part = Array(pending.prefix(batch))
        let ids = Set(part.compactMap { $0["id"] as? String })
        guard let body = try? JSONSerialization.data(withJSONObject: ["install": install, "events": part]) else { return }
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        sending = true
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            queue.async {
                sending = false
                // принято или отвергнуто насовсем (кривая пачка, лимит) — убрать; сбой сети или Яндекса — оставить
                guard (200..<300).contains(code) || [400, 413, 429].contains(code) else { return }
                pending.removeAll { ids.contains($0["id"] as? String ?? "") }
                save()
                if !pending.isEmpty { queue.asyncAfter(deadline: .now() + 2) { flush() } }
            }
        }.resume()
    }

    // MARK: События с состоянием

    /// После проверки «Компонентов» (при каждом показе окна): `open` — раз в день, `components` — когда набор
    /// недостающего изменился (так видно, дошёл ли человек от «нет yt-dlp» до «всё готово»).
    static func checked(_ setup: Setup) {
        guard enabled else { return }
        let d = UserDefaults.standard
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        if d.string(forKey: "statsOpenDay") != day {
            d.set(day, forKey: "statsOpenDay")
            send("open", ["chrome": setup.browsers.contains(where: \.extensionInstalled),
                          "safari": setup.safari == .enabled,
                          "remote": RemoteReceiver.shared.enabled,
                          "lang": String((Locale.preferredLanguages.first ?? "").prefix(2))])
        }
        var missing = setup.missing.map(\.id)
        let text = missing.isEmpty ? "none" : missing.joined(separator: ",")
        if d.string(forKey: "statsMissing") != text {
            d.set(text, forKey: "statsMissing")
            send("components", ["missing": text, "ytdlp": ytdlpVersion(setup) ?? "none"])
        }
    }

    static func ytdlpVersion(_ setup: Setup = .shared) -> String? {
        setup.components.first { $0.id == "yt-dlp" }?.version
    }

    /// Сайт — только из списка поддерживаемых, остальные — «other» (адрес чужого сайта не отправляется).
    static func site(_ name: String) -> String {
        Source.sites.contains { $0.name == name } ? name : "other"
    }
}

extension DownloadJob {
    var statProps: [String: Any] {
        var p: [String: Any] = ["site": Stats.site(sourceName), "kind": statKind]
        if let origin { p["origin"] = origin }
        if statKind == "video", let i = arguments.firstIndex(of: "-S"), i + 1 < arguments.endIndex {
            let sort = arguments[i + 1]
            var quality = sort.range(of: #"res:(\d+)"#, options: .regularExpression).map { String(sort[$0].dropFirst(4)) } ?? "max"
            if sort.hasPrefix("vcodec:h264") { quality += "+h264" }
            p["quality"] = quality
        }
        return p
    }

    var statKind: String {
        if gallery != nil { return "gallery" }
        if let i = arguments.firstIndex(of: "--audio-format"), i + 1 < arguments.endIndex { return arguments[i + 1] }
        return "video"
    }
}

extension TorrentJob {
    var statProps: [String: Any] {
        var p: [String: Any] = ["kind": isFile ? "file" : "torrent"]
        if let origin = record.origin { p["origin"] = origin }
        return p
    }
}
