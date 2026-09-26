import SwiftUI

// MARK: - Плейлисты и каналы

/// Ссылка на плейлист или канал открывает окно выбора роликов (как «Новая загрузка» у торрентов).
/// Одиночные видео — в том числе `watch?v=…&list=…` — качаются как раньше, без окна (`--no-playlist`).
enum Playlist {
    /// Ссылка на список роликов — или nil, если это одиночное видео. Канал без вкладки — его вкладка «Видео»:
    /// у корня канала yt-dlp отдаёт не ролики, а вкладки (Видео, Трансляции, Shorts).
    static func listURL(_ raw: String) -> String? {
        guard let u = URLComponents(string: raw), let host = u.host?.lowercased() else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            if u.path == "/playlist", u.queryItems?.contains(where: { $0.name == "list" }) == true { return raw }
            guard let first = parts.first else { return nil }
            let base: Int
            if first.hasPrefix("@") { base = 1 } else if ["channel", "c", "user"].contains(first), parts.count > 1 { base = 2 } else { return nil }
            let channel = "https://www.youtube.com/" + parts.prefix(base).joined(separator: "/")
            if parts.count > base, ["videos", "shorts", "streams"].contains(parts[base]) { return channel + "/" + parts[base] }
            return channel + "/videos"
        }
        if host.hasSuffix("vkvideo.ru") || host.hasSuffix("vk.com") || host.hasSuffix("vk.ru"), parts.first == "playlist" {
            return raw
        }
        return nil
    }

    static func isChannel(_ url: String) -> Bool { !url.contains("/playlist") }

    /// Ролик, открытый из плейлиста YouTube (watch?v=…&list=…, youtu.be/…?list=…), — адрес самого плейлиста.
    /// Такая ссылка качает одно видео; из поля ввода DownMax спрашивает, не нужен ли весь плейлист.
    /// Миксы (RD…) — не плейлисты, а подборка YouTube; «Смотреть позже» и «Понравившиеся» без входа не открыть.
    static func watchList(_ raw: String) -> String? {
        guard let u = URLComponents(string: raw), let host = u.host?.lowercased(),
              host == "youtu.be" || (host == "youtube.com" || host.hasSuffix(".youtube.com")) && u.path == "/watch",
              let list = u.queryItems?.first(where: { $0.name == "list" })?.value, !list.isEmpty,
              !["RD", "WL", "LL", "UL"].contains(where: list.hasPrefix) else { return nil }
        return "https://www.youtube.com/playlist?list=" + list
    }
}

final class PendingPlaylist: ObservableObject, Identifiable {
    struct Entry: Identifiable {
        let id: Int          // номер в списке, с 1
        let title: String?
        let duration: Double?
        let url: String
    }

    let id = UUID()
    let url: String
    let mode: Mode?
    let maxHeight: Int?
    let origin: String
    /// Со страницы (из расширения): название плейлиста и названия роликов — VK в списке yt-dlp их не отдаёт.
    let pageTitle: String?
    let names: [String: String]
    /// Сколько роликов канала показывать: самые новые, больше за раз обычно не нужно, а тысячи грузятся долго.
    static let channelLimit = 200

    @Published var title: String?
    @Published var entries: [Entry] = []
    @Published var loaded = false
    @Published var error: String?
    private var process: Process?

    var isChannel: Bool { Playlist.isChannel(url) }

    init(url: String, mode: Mode?, maxHeight: Int?, origin: String, pageTitle: String? = nil, names: [String: String] = [:]) {
        self.url = url
        self.mode = mode
        self.maxHeight = maxHeight
        self.origin = origin
        self.pageTitle = pageTitle?.isEmpty == true ? nil : pageTitle
        self.names = names
    }

    func load() {
        guard let ytdlp = Tools.find("yt-dlp") else {
            error = "Не найден yt-dlp. Установите его в «Компонентах» внизу окна."
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ytdlp)
        p.arguments = ["--flat-playlist", "-J", "--no-warnings", "--playlist-end", String(Self.channelLimit), "--", url]
        p.environment = Tools.environment
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        process = p
        DispatchQueue.global(qos: .userInitiated).async {
            do { try p.run() } catch {
                DispatchQueue.main.async { self.error = "Не удалось запустить yt-dlp." }
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let list = (json?["entries"] as? [[String: Any]] ?? []).enumerated().compactMap { i, e -> Entry? in
                guard let link = e["url"] as? String ?? e["webpage_url"] as? String else { return nil }
                let key = link.range(of: #"-?\d+_\d+"#, options: .regularExpression).map { String(link[$0]) }
                return Entry(id: i + 1, title: e["title"] as? String ?? key.flatMap { self.names[$0] },
                             duration: e["duration"] as? Double, url: link)
            }
            DispatchQueue.main.async {
                guard self.process === p else { return }  // отменено
                self.process = nil
                // у канала yt-dlp добавляет вкладку: «jawed - Videos» — для папки и заголовка хватит «jawed»
                self.title = (json?["title"] as? String).map { t in
                    [" - Videos", " - Shorts", " - Live"].reduce(t) { $0.hasSuffix($1) ? String($0.dropLast($1.count)) : $0 }
                } ?? self.pageTitle
                self.entries = list
                self.loaded = true
                if list.isEmpty {
                    let raw = errText.split(separator: "\n").last { $0.hasPrefix("ERROR:") }.map(String.init)
                    self.error = raw.map { Failure.video($0) } ?? "В плейлисте нет видео."
                }
            }
        }
    }

    func cancel() {
        let p = process
        process = nil
        p?.terminate()
    }
}

extension DownloadManager {
    /// Плейлист или канал: окно выбора роликов. Один ролик в списке — сразу качается, без окна.
    func openPlaylist(_ url: String, mode: Mode?, maxHeight: Int?, origin: String, title: String? = nil,
                      names: [String: String] = [:]) {
        pendingPlaylist?.cancel()
        let p = PendingPlaylist(url: url, mode: mode, maxHeight: maxHeight, origin: origin, pageTitle: title, names: names)
        pendingPlaylist = p
        p.load()
        NSApp.activate()
    }

    /// «Скачать» в окне: каждый ролик — отдельная загрузка (очередь с лимитом не даст им пойти разом), в свою папку.
    /// В плейлисте файлы нумеруются по порядку («01 Введение»), у канала — нет: там порядок — просто новизна.
    func downloadPlaylist(_ p: PendingPlaylist, selected: Set<Int>, baseFolder: String) {
        let name = sanitizeFilename(p.title ?? (p.isChannel ? "Канал" : "Плейлист"))
        let folder = Self.uniquePath(baseFolder + "/" + name, ext: nil)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let digits = max(2, String(p.entries.count).count)
        for e in p.entries where selected.contains(e.id) {
            let prefix = p.isChannel ? nil : String(format: "%0\(digits)d", e.id)
            // в строке очереди — название из окна (у VK — со страницы), пока yt-dlp не сообщил своё
            let shown = e.title.map { t in prefix.map { "\($0) \(t)" } ?? t }
            download(url: e.url, mode: p.mode, maxHeight: p.maxHeight, folder: folder, prefix: prefix,
                     displayTitle: shown, origin: p.origin)
        }
    }
}

// MARK: - Окно выбора роликов

struct PlaylistSheet: View {
    @ObservedObject var pending: PendingPlaylist
    @ObservedObject var manager: DownloadManager
    @AppStorage("folder") private var folder = NSHomeDirectory() + "/Downloads"
    @AppStorage("mode") private var modeRaw = Mode.video.rawValue
    @AppStorage("quality") private var qualityRaw = 0
    @AppStorage("compatible") private var compatible = false
    @State private var selected: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(pending.isChannel ? "Канал" : "Плейлист").font(.title2.bold())

            if let error = pending.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if pending.loaded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(heading).font(.headline).lineLimit(2).truncationMode(.middle)
                    folderRow
                }
                list
                Text(modeText).font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Получаю список видео…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Отмена", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(selected.isEmpty ? "Скачать" : "Скачать \(selected.count)") {
                    manager.downloadPlaylist(pending, selected: selected, baseFolder: folder)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.brandFill)
                .disabled(!pending.loaded || selected.isEmpty)
            }
            .controlSize(.large)
            .padding(.top, 8)  // 24 от содержимого: кнопки — отдельная группа
        }
        .padding(24)
        .buttonStyle(.gray)
        .frame(width: 620)
        .onChange(of: pending.loaded) { _, _ in selected = Set(pending.entries.map(\.id)) }
    }

    private var heading: String {
        let name = pending.title ?? (pending.isChannel ? "Канал" : "Плейлист")
        let count = pending.entries.count
        // список обрезан на 200: у канала это самые новые, у плейлиста — первые
        let more = count >= PendingPlaylist.channelLimit ? (pending.isChannel ? " (последние)" : " (первые)") : ""
        return "\(name) · \(count) видео\(more)"
    }

    /// Папка — новая, по названию плейлиста, внутри «Сохранять в».
    private var folderRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(folder + "/" + sanitizeFilename(pending.title ?? (pending.isChannel ? "Канал" : "Плейлист")))
                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            Button("Изменить…", action: chooseFolder).buttonStyle(.brandLink).padding(.leading, 2)
            Spacer()
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Видео: \(pending.entries.count)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Выбрать все") { selected = Set(pending.entries.map(\.id)) }.buttonStyle(.brandLink)
                Button("Снять выделение") { selected = [] }.buttonStyle(.brandLink)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(pending.entries) { row($0) }
                }
                .padding(.vertical, 6)
            }
            .frame(height: min(CGFloat(pending.entries.count) * 26 + 12, 300))
            .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Color.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Color.hairline))
        }
    }

    private func row(_ e: PendingPlaylist.Entry) -> some View {
        let on = selected.contains(e.id)
        return Button {
            if on { selected.remove(e.id) } else { selected.insert(e.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? AnyShapeStyle(Color.brand) : AnyShapeStyle(.secondary))
                Text("\(e.id).").foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: numberWidth, alignment: .trailing)  // «9.» и «10.» — названия с одной линии
                Text(e.title ?? "Видео \(e.id)").lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 12)
                if let d = e.duration { Text(Self.clock(d)).foregroundStyle(.secondary).monospacedDigit() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .accessibilityValue(on ? "выбрано" : "не выбрано")
    }

    /// Колонка номера — по самому длинному номеру: «200.» шире, чем «9.».
    private var numberWidth: CGFloat { CGFloat(String(pending.entries.count).count + 1) * 8 }

    /// 754 → «12:34», 3754 → «1:02:34».
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private var modeText: String {
        let mode = pending.mode ?? Mode(rawValue: modeRaw) ?? .video
        guard mode == .video else { return mode.rawValue }
        let quality = pending.maxHeight.map { "до \($0)p" } ?? (Quality(rawValue: qualityRaw) ?? .best).title
        return "Видео · " + quality + (compatible ? " · без перекодирования" : "") + ", как выбрано в окне"
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
        manager.pendingPlaylist = nil
    }
}
