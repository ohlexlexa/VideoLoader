import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLookThumbnailing

// MARK: - Откуда загрузка

/// Метка источника в строке: «YouTube», «Торрент», «Файл», для прочих сайтов — адрес сайта.
/// Новый поддерживаемый сайт добавляется в `sites` — он сразу появится и в метках, и в фильтре над списком.
enum Source {
    static let sites: [(name: String, domains: [String])] = [
        ("YouTube", ["youtube.com", "youtu.be", "youtube-nocookie.com", "googlevideo.com"]),
        ("Instagram", ["instagram.com"]),
        // видео Threads — прямые mp4 с CDN Instagram/Facebook (одиночное видео Instagram идёт ссылкой на пост)
        ("Threads", ["threads.com", "threads.net", "cdninstagram.com", "fbcdn.net"]),
        ("VK", ["vk.com", "vkvideo.ru", "vk.ru", "userapi.com"]),
        ("Vimeo", ["vimeo.com"]),
        ("GetCourse", ["getcourse.ru", "gcdn.co"]),
        // Их качает сам yt-dlp; проверены 2026-09-26. Одноклассники пока сломаны в yt-dlp — добавить, когда починят.
        ("TikTok", ["tiktok.com"]),
        ("Rutube", ["rutube.ru"]),
        ("Дзен", ["dzen.ru", "zen.yandex.ru"]),
        ("X", ["x.com", "twitter.com"]),
        ("Pinterest", ["pinterest.com", "pinterest.ru", "pin.it"]),
        ("Telegram", ["t.me", "telegram.me"]),
        ("Twitch", ["twitch.tv"]),
    ]
    static let torrent = "Торрент"
    static let file = "Файл"
    /// Всё, что есть в фильтре над списком, по порядку; прочие сайты — отдельным пунктом «Другие сайты».
    static var filterNames: [String] { sites.map(\.name) + [torrent, file] }
    static func isOther(_ name: String) -> Bool { !filterNames.contains(name) }

    /// Прямые ссылки на файл с серверов раздачи — временные (срок в самой ссылке): показывать их незачем.
    static func isTemporary(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return true }
        let cdn = ["cdninstagram.com", "fbcdn.net", "googlevideo.com", "userapi.com", "vkuservideo.net", "okcdn.ru"]
        return cdn.contains { host == $0 || host.hasSuffix("." + $0) } || url.contains("/api/playlist/master/")
    }

    static func name(of url: String) -> String {
        if url == "gallery" { return "Instagram" }  // карусели и фото приходят только из окошка на Instagram
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return "Ссылка" }
        for site in sites where site.domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return site.name
        }
        // GetCourse на своём домене школы: поток узнаётся по адресу плейлиста
        if url.contains("/api/playlist/master/") { return "GetCourse" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

extension DownloadJob {
    var sourceName: String { Source.name(of: page ?? url) }

    /// Что показать в подробностях: страница, откуда взято; временную ссылку на файл — нет.
    var pageLink: String? {
        if let page { return page }
        return gallery == nil && !Source.isTemporary(url) ? url : nil
    }

    /// Папка, выбранная для этой загрузки в момент нажатия «Скачать».
    var folder: String? {
        if let target = galleryTarget { return (target as NSString).deletingLastPathComponent }
        var i = arguments.startIndex
        while let p = arguments[i...].firstIndex(of: "-P"), p + 1 < arguments.endIndex {
            if !arguments[p + 1].hasPrefix("temp:") { return arguments[p + 1] }
            i = p + 1
        }
        return nil
    }

    /// «Видео · до 1080p · без перекодирования», «Звук mp3», «Фото и видео».
    var modeText: String {
        if gallery != nil { return "Фото и видео" }
        if let i = arguments.firstIndex(of: "--audio-format"), i + 1 < arguments.endIndex {
            return "Звук " + arguments[i + 1]
        }
        var parts = ["Видео"]
        if let i = arguments.firstIndex(of: "-S"), i + 1 < arguments.endIndex {
            let sort = arguments[i + 1]
            if let r = sort.range(of: #"res:(\d+)"#, options: .regularExpression) {
                parts.append("до " + sort[r].dropFirst(4) + "p")
            } else {
                parts.append("максимальное качество")
            }
            if sort.hasPrefix("vcodec:h264") { parts.append("без перекодирования") }
        }
        return parts.joined(separator: " · ")
    }
}

extension DownloadJob {
    /// «Готово · 3 фото и 2 видео · 12 МБ · сегодня, 14:05» — без имени файла: оно в заголовке строки.
    var doneLine: String {
        var parts = [fileDeleted ? "Файл удалён" : "Готово"]
        if let note { parts.append(note) }
        if !fileDeleted, let size = fileSize { parts.append(bytes(Double(size))) }
        if let date = doneDate { parts.append(DoneDate.text(date)) }
        return parts.joined(separator: " · ")
    }

    /// Когда скачано. У записей до 2.0 даты нет — берём дату создания файла.
    var doneDate: Date? {
        finished ?? filePath.flatMap { DoneDate.created($0) }
    }

    /// Размер готового файла; у папки (карусель) — nil.
    var fileSize: Int64? {
        guard let path = filePath, let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType != .typeDirectory else { return nil }
        return attrs[.size] as? Int64
    }
}

/// Дата завершения загрузки: «сегодня, 14:05», «вчера, 09:30», «12 сент., 18:20», «3 мар. 2025, 11:00».
enum DoneDate {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = format
        return f
    }
    private static let time = formatter("HH:mm")
    private static let day = formatter("d MMM, HH:mm")
    private static let dayYear = formatter("d MMM yyyy, HH:mm")

    /// Дата создания файла — для загрузок, у которых дата завершения не сохранялась.
    static func created(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
    }

    static func text(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "сегодня, " + time.string(from: date) }
        if cal.isDateInYesterday(date) { return "вчера, " + time.string(from: date) }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: Date())
        return (sameYear ? day : dayYear).string(from: date)
    }
}

extension TorrentJob {
    /// Когда скачано; у записей до 2.0 — дата создания файлов.
    var doneDate: Date? { record.finished ?? (filesDeleted ? nil : DoneDate.created(target)) }

    var sourceName: String { isFile ? Source.file : Source.torrent }
}

/// Серая метка перед строкой состояния.
struct SourceTag: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)))  // метка ~17 — четверть
            .fixedSize()
    }
}

private func bytes(_ v: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file)
}

// MARK: - Общая скорость внизу окна

/// «↓ 5 МБ/с  ↑ 200 КБ/с» — по всем идущим загрузкам и раздачам; пусто, когда ничего не идёт.
/// Скорости живут в самих загрузках, поэтому строка пересчитывается раз в секунду.
struct TransferTotals: View {
    @ObservedObject var manager: DownloadManager
    @ObservedObject var torrents: TorrentManager

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let down = manager.jobs.reduce(0) { $0 + $1.speed } + torrents.torrents.reduce(0) { $0 + $1.downSpeed }
            let up = torrents.torrents.reduce(0) { $0 + $1.upSpeed }
            let active = manager.jobs.contains(where: \.isRunning)
                || torrents.torrents.contains { $0.state == .downloading || $0.state == .seeding }
            if active {
                HStack(spacing: 10) {
                    Text("↓ \(bytes(down))/с")
                    if torrents.torrents.contains(where: { $0.state == .downloading || $0.state == .seeding }) {
                        Text("↑ \(bytes(up))/с")
                    }
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Общая скорость загрузки и раздачи")
            }
        }
    }
}

// MARK: - Подробности по щелчку на строку

/// Текст, который можно скопировать правым щелчком; путь к файлу или папке — ещё и показать в Finder.
private struct CopyableText: View {
    let text: String
    var path: String? = nil
    var link: URL? = nil
    /// Щелчок открывает Finder с выделенным файлом (путь к папке загрузки в подробностях).
    var reveal: String? = nil

    var body: some View {
        label
            .lineLimit(1)
            .truncationMode(.middle)
            .help(link != nil ? "Открыть в браузере · правый щелчок — скопировать"
                  : reveal != nil ? "Показать в Finder · правый щелчок — скопировать" : text)
            .contextMenu {
                Button("Копировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                if let path, FileManager.default.fileExists(atPath: path) {
                    Button("Показать в Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                if let link { Button("Открыть в браузере") { NSWorkspace.shared.open(link) } }
            }
    }

    /// Ссылка — розовая, как остальные ссылки в окне, и открывается щелчком; путь и прочее — обычный текст.
    @ViewBuilder private var label: some View {
        if let link {
            Button(text) { NSWorkspace.shared.open(link) }
                .buttonStyle(.brandLink)
                .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        } else if let reveal {
            Button { Finder.reveal(reveal) } label: {
                Label(text, systemImage: "folder")
            }
            .buttonStyle(.brandLink)
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        } else {
            Text(text)
        }
    }
}

enum Finder {
    /// Открывает папку в Finder и выделяет в ней файл; если файла уже нет — просто открывает папку.
    static func reveal(_ path: String) {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: (path as NSString).deletingLastPathComponent))
        }
    }
}

private let addedFormat: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
}()

/// Панель под списком: сведения о выбранной загрузке. Закрывается крестиком или повторным щелчком по строке.
struct DetailsPanel: View {
    let id: UUID
    @ObservedObject var manager: DownloadManager
    @ObservedObject var torrents: TorrentManager
    let close: () -> Void

    var body: some View {
        Group {
            if let job = manager.jobs.first(where: { $0.id == id }) {
                VideoDetails(job: job, close: close)
            } else if let job = torrents.torrents.first(where: { $0.id == id }) {
                TorrentDetails(job: job, close: close)
            }
        }
        .id(id)  // другая строка — панель заново: иначе остаются формат и вкладка от прошлой загрузки
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)  // высота — по содержимому
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Color.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Color.hairline))
    }
}

/// «Загружено: 644 МБ» — подпись серым, значение обычным; строки столбиком в `Grid`.
private struct Pair<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label + ":").foregroundStyle(.secondary)
            value.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Превью файла, как в Finder (Quick Look): кадр видео, картинка, обложка у звука. Нет превью — у папки,
/// образа диска, у недокачанного — значок из Finder (свой у файла или по типу).
private struct FileIcon: View {
    let path: String?
    let fallback: UTType
    @State private var preview: NSImage?

    var body: some View {
        Group {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))  // превью внутри панели 16 — вполовину
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline))
                    .frame(maxWidth: 128, maxHeight: 96)
            } else {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 104, height: 104)
            }
        }
        .frame(width: 128)  // одно место и под превью, и под значок — текст справа не прыгает
        .task(id: path) { preview = await Self.thumbnail(path) }
    }

    private var icon: NSImage {
        if let path, FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
        return NSWorkspace.shared.icon(for: fallback)
    }

    /// Только настоящее превью (`.thumbnail`): вместо значка файла Quick Look тоже отдаёт значок — такой не берём.
    private static func thumbnail(_ path: String?) async -> NSImage? {
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 256, height: 192),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

/// Иконка слева, справа — название, путь к папке и сведения; как панель «Основное» у FDM.
private struct DetailsLayout<Tabs: View, Content: View>: View {
    let title: String
    let source: String
    let folder: String?
    /// Файл, который выделить в Finder по щелчку на папку или иконку.
    let reveal: String?
    let icon: FileIcon
    let progress: Double?
    let close: () -> Void
    @ViewBuilder let tabs: Tabs
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Button { if let target = reveal ?? folder { Finder.reveal(target) } } label: { icon }
                .buttonStyle(.plain)
                .help("Показать в Finder")
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    CopyableText(text: title).font(.title3.weight(.semibold))
                    SourceTag(name: source)
                    Spacer(minLength: 8)
                    tabs
                    IconButton("xmark", "Закрыть", action: close)
                        .padding(.trailing, -7)  // крестик, а не поле 28, — у края панели
                }
                .frame(minHeight: Metrics.regular)
                if let folder {
                    CopyableText(text: folder, path: folder, reveal: reveal ?? folder)
                }
                if let progress {
                    HStack(spacing: 10) {
                        LoadBar(value: progress)
                        Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)  // заголовок с путём — одна группа, свойства — другая
            }
        }
    }
}

private struct VideoDetails: View {
    @ObservedObject var job: DownloadJob
    let close: () -> Void
    /// «1920×1080 · H.264 · AAC» — по готовому файлу (ffprobe), считается при открытии панели.
    @State private var fileInfo: String?

    var body: some View {
        DetailsLayout(title: job.title, source: job.sourceName, folder: job.folder,
                      reveal: job.fileDeleted ? nil : (job.filePath ?? job.galleryTarget),
                      icon: FileIcon(path: job.fileDeleted ? nil : job.filePath, fallback: fallback),
                      progress: [.downloading, .paused].contains(job.state) ? job.progress : nil,
                      close: close) {
            EmptyView()
        } content: {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                Pair("Формат") { Text([job.modeText, fileInfo].compactMap { $0 }.joined(separator: " · ")) }
                if let added = job.added { Pair("Добавлено") { Text(addedFormat.string(from: added)) } }
                Pair("Загружено") { Text(amount) }
                if job.state != .done {
                    Pair("Состояние") { Text(job.detail).foregroundStyle(job.state == .failed ? .red : .primary) }
                }
                if job.state == .failed, let raw = job.error {
                    Pair("Текст ошибки") { CopyableText(text: raw).foregroundStyle(.secondary) }
                }
                if job.speed > 0 { Pair("Скорость") { Text("↓ \(bytes(job.speed))/с") } }
                if let link = job.pageLink {
                    Pair("Ссылка") { CopyableText(text: link, link: URL(string: link)) }
                }
            }
            .font(.callout)
        }
        .task(id: job.state) { await loadFileInfo() }
    }

    private var fallback: UTType {
        if job.gallery != nil { return .folder }
        return job.modeText.hasPrefix("Звук") ? .audio : .movie
    }

    private var amount: String {
        if job.state == .done { return job.fileSize.map { bytes(Double($0)) } ?? "—" }
        return job.amounts ?? "—"
    }

    private func loadFileInfo() async {
        guard job.state == .done, let path = job.filePath, !job.fileDeleted,
              FileManager.default.fileExists(atPath: path), let ffprobe = Tools.find("ffprobe") else { return }
        let info = await Task.detached(priority: .utility) { () -> String? in
            let video = Tools.firstLine(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                                  "stream=codec_name,width,height", "-of", "csv=p=0", path])
            let audio = Tools.firstLine(ffprobe, ["-v", "error", "-select_streams", "a:0", "-show_entries",
                                                  "stream=codec_name", "-of", "csv=p=0", path])
            let names = ["h264": "H.264", "hevc": "HEVC", "vp9": "VP9", "av1": "AV1", "aac": "AAC", "mp3": "MP3",
                         "opus": "Opus", "vorbis": "Vorbis", "mjpeg": "JPEG", "png": "PNG"]
            var parts: [String] = []
            if let v = video?.split(separator: ","), v.count == 3, !v[0].isEmpty,
               v[0] != "mjpeg" && v[0] != "png" {  // обложка у mp3/m4a — не видео
                parts.append("\(v[1])×\(v[2])")
                parts.append(names[String(v[0])] ?? v[0].uppercased())
            }
            if let a = audio, !a.isEmpty { parts.append(names[a] ?? a.uppercased()) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }.value
        fileInfo = info
    }
}

private struct TorrentDetails: View {
    @ObservedObject var job: TorrentJob
    let close: () -> Void
    @State private var tab = "main"

    var body: some View {
        DetailsLayout(title: job.name, source: job.sourceName, folder: job.record.folder,
                      reveal: job.filesDeleted ? nil : job.target,
                      icon: FileIcon(path: job.filesDeleted ? nil : job.target,
                                     fallback: job.isFile ? .data : (job.record.root.contains(".") ? .data : .folder)),
                      progress: job.state == .downloading || job.state == .paused ? job.progress : nil,
                      close: close) {
            if !job.isFile {
                Tabs(selection: $tab, options: [("main", "Основное"), ("files", "Файлы")])
                    .fixedSize()
            }
        } content: {
            if tab == "files" && !job.isFile {
                TorrentFiles(job: job)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    if let added = job.record.added { Pair("Добавлено") { Text(addedFormat.string(from: added)) } }
                    Pair("Загружено") { Text(amount) }
                    if !job.isFile { Pair("Отдано") { Text("\(bytes(job.uploaded)) (рейтинг: \(job.ratio))") } }
                    Pair("Состояние") { Text(stateText).foregroundStyle(job.state == .failed ? .red : .primary) }
                    if job.state == .failed, let raw = job.record.error {
                        Pair("Текст ошибки") { CopyableText(text: raw).foregroundStyle(.secondary) }
                    }
                    if job.isActive {
                        Pair("Скорость") {
                            Text(job.isFile ? "↓ \(bytes(job.downSpeed))/с"
                                            : "↓ \(bytes(job.downSpeed))/с  ↑ \(bytes(job.upSpeed))/с")
                        }
                        if !job.isFile, let peers = job.peers {
                            Pair("Участники") { Text("\(peers)" + (job.seeders.map { ", раздают целиком: \($0)" } ?? "")) }
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    private var amount: String {
        if job.state == .done || job.state == .seeding { return bytes(Double(job.record.size)) }
        return job.record.amounts ?? "0 Б из \(bytes(Double(job.record.size)))"
    }

    private var stateText: String {
        switch job.state {
        case .downloading: "Качается"
        case .queued: "В очереди"
        case .paused: "Пауза"
        case .seeding: "Раздаётся, пока не нажмёте ■ в строке"
        case .done: job.canSeed ? "Готово · можно раздавать (↑ в строке)" : "Готово"
        case .failed: job.detail
        }
    }
}

/// Файлы торрента с ходом каждого. aria2c без RPC не сообщает ход по файлам, поэтому он считается по диску:
/// файлы пишутся «дырявыми» (без предвыделения), и занятое место растёт вместе со скачанными кусками.
private struct TorrentFiles: View {
    @ObservedObject var job: TorrentJob
    @State private var files: [TorrentFile] = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(files) { file in
                        HStack(spacing: 10) {
                            CopyableText(text: shortPath(file.path), path: job.record.folder + "/" + file.path)
                            Spacer(minLength: 8)
                            ProgressView(value: share(file)).tint(.brand).frame(width: 90)
                            Text(bytes(Double(file.size))).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                }
                .font(.callout)
            }
            // длинный список файлов прокручивается, короткий — панель по нему
            .frame(height: min(CGFloat(max(files.count, 1)) * 24, 200))
        }
        .task(id: job.id) {
            let (torrent, selected) = (job.record.torrent, job.record.selected)
            let all = await Task.detached(priority: .utility) { Aria2.info(torrent)?.files ?? [] }.value
            files = selected.map { chosen in all.filter { chosen.contains($0.index) } } ?? all
        }
    }

    /// «Sintel/Sintel.mp4» → «Sintel.mp4»: папка торрента и так в заголовке.
    private func shortPath(_ path: String) -> String {
        let prefix = job.record.root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private func share(_ file: TorrentFile) -> Double {
        if job.state == .done || job.state == .seeding { return 1 }
        guard file.size > 0 else { return 1 }
        var st = stat()
        guard lstat(job.record.folder + "/" + file.path, &st) == 0 else { return 0 }
        return min(Double(st.st_blocks) * 512 / Double(file.size), 1)
    }
}
