import SwiftUI
import AppKit

// MARK: - Одна строка списка: видео или торрент/файл

/// Видео (yt-dlp) и торренты с файлами (aria2c) живут в разных списках — для сортировки и фильтров
/// они сводятся в один.
enum ListItem: Identifiable {
    case video(DownloadJob)
    case torrent(TorrentJob)

    var id: UUID {
        switch self {
        case .video(let j): j.id
        case .torrent(let j): j.id
        }
    }

    var title: String {
        switch self {
        case .video(let j): j.title
        case .torrent(let j): j.name
        }
    }

    var source: String {
        switch self {
        case .video(let j): j.sourceName
        case .torrent(let j): j.sourceName
        }
    }

    var added: Date? {
        switch self {
        case .video(let j): j.added
        case .torrent(let j): j.record.added
        }
    }

    var size: Int64 {
        switch self {
        case .video(let j): j.fileSize ?? 0
        case .torrent(let j): j.record.size
        }
    }

    /// Готовый файл (у карусели — папка), который сейчас лежит на диске.
    var filePath: String? {
        let path: String?
        switch self {
        case .video(let j): path = j.state == .done && !j.fileDeleted ? (j.filePath ?? j.galleryTarget) : nil
        case .torrent(let j): path = (j.state == .done || j.state == .seeding) && !j.filesDeleted ? j.target : nil
        }
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    var status: Status {
        switch self {
        case .video(let j):
            switch j.state {
            case .queued, .starting, .downloading, .processing: .downloading  // ждущие — тоже «активные»
            case .paused: .paused
            case .done: .done
            case .failed, .cancelled: .failed
            }
        case .torrent(let j):
            switch j.state {
            case .queued, .downloading: .downloading
            case .seeding: .seeding
            case .paused: .paused
            case .done: .done
            case .failed: .failed
            }
        }
    }

    /// Порядок «по статусу»: сначала то, что идёт, в конце готовое.
    enum Status: Int { case downloading, seeding, paused, failed, done }
}

// MARK: - Сортировка и фильтры

enum ListSort: String, CaseIterable {
    case newest, oldest, az, za, biggest, smallest, activeFirst, doneFirst

    var title: String {
        switch self {
        case .newest: "Новые"
        case .oldest: "Старые"
        case .az: "А–Я"
        case .za: "Я–А"
        case .biggest: "По размеру: большие"
        case .smallest: "По размеру: маленькие"
        case .activeFirst: "По статусу: сначала идущие"
        case .doneFirst: "По статусу: сначала готовые"
        }
    }
}

enum StatusFilter: String, CaseIterable {
    case all, active, done, unfinished

    var title: String {
        switch self {
        case .all: "Все загрузки"
        case .active: "Активные"
        case .done: "Завершённые"
        case .unfinished: "Незавершённые"
        }
    }

    func matches(_ s: ListItem.Status) -> Bool {
        switch self {
        case .all: true
        case .active: s == .downloading || s == .seeding
        case .done: s == .done
        case .unfinished: s != .done
        }
    }
}

enum ListFilter {
    /// «Другие сайты» в фильтре источников.
    static let otherSites = "*other"

    static func items(videos: [DownloadJob], torrents: [TorrentJob], sort: ListSort,
                      status: StatusFilter, source: String) -> [ListItem] {
        // Исходный порядок — новые сверху (так их добавляют); он же — порядок при равных значениях.
        let all = (torrents.map(ListItem.torrent) + videos.map(ListItem.video)).enumerated().sorted {
            ($0.element.added ?? .distantPast, -$0.offset) > ($1.element.added ?? .distantPast, -$1.offset)
        }.map(\.element)
        let visible = all.filter { item in
            status.matches(item.status)
                && (source.isEmpty || item.source == source || (source == otherSites && Source.isOther(item.source)))
        }
        let order = visible.enumerated().map { ($0.offset, $0.element) }
        let sorted: [(Int, ListItem)]
        switch sort {
        case .newest: sorted = order
        case .oldest: sorted = order.reversed()
        case .az, .za:
            sorted = order.sorted {
                let r = $0.1.title.localizedStandardCompare($1.1.title)
                return r == .orderedSame ? $0.0 < $1.0 : (sort == .az ? r == .orderedAscending : r == .orderedDescending)
            }
        case .biggest, .smallest:
            sorted = order.sorted {
                $0.1.size == $1.1.size ? $0.0 < $1.0 : (sort == .biggest ? $0.1.size > $1.1.size : $0.1.size < $1.1.size)
            }
        case .activeFirst, .doneFirst:
            sorted = order.sorted {
                let (a, b) = ($0.1.status.rawValue, $1.1.status.rawValue)
                return a == b ? $0.0 < $1.0 : (sort == .activeFirst ? a < b : a > b)
            }
        }
        return sorted.map(\.1)
    }
}

// MARK: - Меню под кнопкой

/// Пункт меню под кнопкой панели: с галочкой у выбранного, или разделитель.
struct MenuEntry {
    let title: String
    var checked = false
    var action: (() -> Void)?

    static let separator = MenuEntry(title: "", action: nil)
}

/// Кнопка, которая открывает обычное меню macOS под собой. У SwiftUI `Menu` на macOS свой вид
/// кнопки, без наведения, — поэтому кнопка своя, а меню системное.
struct MenuButton<Label: View>: View {
    let entries: () -> [MenuEntry]
    @ViewBuilder let label: Label
    @State private var anchor = Anchor()

    final class Anchor {
        weak var view: NSView?
    }

    var body: some View {
        Button(action: show) { label }
            .background(AnchorView(anchor: anchor))
    }

    private func show() {
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries() {
            if entry.action == nil && entry.title.isEmpty { menu.addItem(.separator()); continue }
            let item = ClosureMenuItem(title: entry.title, action: entry.action ?? {})
            item.state = entry.checked ? .on : .off
            item.isEnabled = entry.action != nil  // строка без действия (путь к папке) — серая, для справки
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    private struct AnchorView: NSViewRepresentable {
        let anchor: Anchor
        func makeNSView(context: Context) -> NSView {
            let v = FlippedView()
            anchor.view = v
            return v
        }
        func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

// MARK: - Панель над списком

/// «☐ ▾   ≡ Новые ▾   ⏷ Все загрузки ▾   …   Выбрано: 3  Пауза  Продолжить  Удалить…» — как у FDM.
struct ListToolbar: View {
    let items: [ListItem]
    let checkedItems: [ListItem]
    @Binding var checked: Set<UUID>
    @Binding var sortRaw: String
    @Binding var statusRaw: String
    @Binding var source: String
    let delete: () -> Void
    @AppStorage(DownloadQueue.key) private var maxConcurrent = DownloadQueue.standard

    private var sort: ListSort { ListSort(rawValue: sortRaw) ?? .newest }
    private var status: StatusFilter { StatusFilter(rawValue: statusRaw) ?? .all }
    private var visibleIDs: Set<UUID> { Set(items.map(\.id)) }
    private var allChecked: Bool { !items.isEmpty && visibleIDs.isSubset(of: checked) }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Button(action: toggleAll) {
                    CheckMark(state: allChecked ? .on : (checked.isDisjoint(with: visibleIDs) ? .off : .mixed))
                        .padding(.leading, 14)  // в одну колонку с галочками строк (поле строки — 14)
                        .padding(.trailing, 6)
                        .frame(height: Metrics.regular)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(allChecked ? "Снять выделение" : "Выбрать все")
                .accessibilityLabel(allChecked ? "Снять выделение" : "Выбрать все")
                MenuButton(entries: selectEntries) {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .frame(height: Metrics.regular)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
                .help("Выбрать…")
            }
            .background(RoundedRectangle(cornerRadius: Metrics.radius(Metrics.regular)).fill(Color.primary.opacity(0.12)))
            .hoverHighlight()

            MenuButton(entries: sortEntries) {
                pill("arrow.up.arrow.down", sort.title)
            }
            MenuButton(entries: filterEntries) {
                pill("line.3.horizontal.decrease", filterTitle)
            }
            // сколько загрузок качается одновременно, остальные — «В очереди»
            MenuButton(entries: limitEntries) {
                pill("square.stack.3d.down.right", DownloadQueue.title(maxConcurrent))
            }
            .help("Сколько загрузок качается одновременно, остальные ждут в очереди")

            Spacer()

            if !checked.isEmpty {
                Text("Выбрано: \(checked.count)").font(.callout).foregroundStyle(.secondary)
                if checkedItems.contains(where: BulkPause.canPause) {
                    Button { BulkPause.pause(checkedItems) } label: { Label("Пауза", systemImage: "pause") }
                        .help("Приостановить отмеченные — идущие и ждущие в очереди")
                }
                if checkedItems.contains(where: BulkPause.canResume) {
                    Button { BulkPause.resume(checkedItems) } label: { Label("Продолжить", systemImage: "play") }
                        .help("Отмеченные на паузе встанут в очередь и начнутся по порядку, сколько разрешено одновременно")
                }
                Button(action: delete) { Label("Удалить…", systemImage: "trash") }
            }
        }
        .buttonStyle(.gray)
    }

    private func pill(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
    }

    private var filterTitle: String {
        let parts = [status == .all ? nil : status.title,
                     source.isEmpty ? nil : (source == ListFilter.otherSites ? "Другие сайты" : source)]
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? "Все загрузки" : text
    }

    private func toggleAll() {
        if allChecked { checked.subtract(visibleIDs) } else { checked.formUnion(visibleIDs) }
    }

    private func selectEntries() -> [MenuEntry] {
        let pick = { (match: @escaping (ListItem.Status) -> Bool) in {
            checked = Set(items.filter { match($0.status) }.map(\.id))
        } }
        return [
            MenuEntry(title: "Все", action: pick { _ in true }),
            MenuEntry(title: "Только загрузки", action: pick { $0 == .downloading }),
            MenuEntry(title: "Только раздачи", action: pick { $0 == .seeding }),
            MenuEntry(title: "Завершённые", action: pick { $0 == .done }),
            MenuEntry(title: "Остановленные", action: pick { $0 == .paused || $0 == .failed }),
            .separator,
            MenuEntry(title: "Снять выделение", action: { checked = [] }),
        ]
    }

    private func sortEntries() -> [MenuEntry] {
        ListSort.allCases.map { s in MenuEntry(title: s.title, checked: s == sort, action: { sortRaw = s.rawValue }) }
    }

    private func limitEntries() -> [MenuEntry] {
        [MenuEntry(title: "Качать одновременно", action: nil)]
            + DownloadQueue.options.map { n in
                MenuEntry(title: DownloadQueue.title(n), checked: n == maxConcurrent) {
                    maxConcurrent = n
                    DownloadQueue.enforce()  // меньше — лишние обратно в очередь, больше — запустить ждущие
                }
            }
    }

    private func filterEntries() -> [MenuEntry] {
        var entries = StatusFilter.allCases.map { f in
            MenuEntry(title: f.title, checked: f == status, action: { statusRaw = f.rawValue })
        }
        entries.append(.separator)
        entries.append(MenuEntry(title: "Все источники", checked: source.isEmpty, action: { source = "" }))
        for name in Source.filterNames {
            entries.append(MenuEntry(title: name, checked: source == name, action: { source = name }))
        }
        entries.append(MenuEntry(title: "Другие сайты", checked: source == ListFilter.otherSites,
                                 action: { source = ListFilter.otherSites }))
        return entries
    }
}

/// Квадрат галочки: пустой, с галочкой или с чертой (выбрана часть).
struct CheckMark: View {
    let state: NSControl.StateValue

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(state == .off ? AnyShapeStyle(Color.primary.opacity(0.06)) : AnyShapeStyle(Color.brand))
            if state == .off {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.3), lineWidth: 1)
            } else {
                Image(systemName: state == .on ? "checkmark" : "minus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 16, height: 16)
    }
}

// MARK: - Удаление отмеченных

/// «Пауза» и «Продолжить» для отмеченных галочками: плейлист на 50 роликов — одним нажатием. Раздачи и
/// перекодирование не трогает — у них нет паузы. «Продолжить» ставит в очередь, а не запускает всё сразу:
/// одиночное «Продолжить» лимит не спрашивает, но 50 загрузок разом забили бы сеть.
enum BulkPause {
    static func canPause(_ item: ListItem) -> Bool {
        switch item {
        case .video(let j): j.canPause || j.state == .queued
        case .torrent(let j): j.state == .downloading || j.state == .queued
        }
    }

    static func canResume(_ item: ListItem) -> Bool {
        switch item {
        case .video(let j): j.state == .paused
        case .torrent(let j): j.state == .paused
        }
    }

    static func pause(_ items: [ListItem]) {
        // Сначала ждущие: иначе место, освобождённое паузой идущей, тут же заняла бы отмеченная ждущая.
        for item in items {
            switch item {
            case .video(let j): j.hold()
            case .torrent(let j): j.hold()
            }
        }
        for item in items where canPause(item) {
            switch item {
            case .video(let j): j.pause()
            case .torrent(let j): j.pause()
            }
        }
    }

    static func resume(_ items: [ListItem]) {
        for item in items where canResume(item) {
            switch item {
            case .video(let j): j.enqueue()
            case .torrent(let j): j.enqueue()
            }
        }
        DownloadQueue.tick()
    }
}

enum BulkDelete {
    /// Спрашивает, что делать с файлами, останавливает идущие загрузки и убирает отмеченные из списка.
    /// Возвращает false, если пользователь передумал.
    @discardableResult
    static func run(_ items: [ListItem]) -> Bool {
        guard !items.isEmpty else { return false }
        // Терять нечего (файла нет, ничего не идёт) — убираем сразу: вопрос без причины приучает жать «Удалить» не читая.
        let nothingToLose = items.allSatisfy { item in
            guard item.filePath == nil else { return false }
            switch item {
            case .video(let j): return !(j.isRunning || j.state == .paused)
            case .torrent(let j): return !(j.isActive || j.state == .paused)
            }
        }
        if nothingToLose {
            for item in items {
                switch item {
                case .video(let job): DownloadManager.shared.remove(job)
                case .torrent(let job): TorrentManager.shared.remove(job)
                }
            }
            return true
        }
        // Вариант «вместе с файлами» — только когда на диске есть что удалять (готовое или недокачанное торрента).
        let hasFiles = items.contains { item in
            if item.filePath != nil { return true }
            if case .torrent(let job) = item { return job.isActive || job.state == .paused }
            return false
        }
        var text: String
        if items.count == 1, let path = items[0].filePath {
            text = path  // как у FDM: видно, какой файл уйдёт в Корзину
        } else {
            text = hasFiles ? "Файлы можно оставить на диске или переместить в Корзину." : "Файлов на диске уже нет."
        }
        // Куски видео лежат в кэше и удаляются всегда; недокачанное торрента и файла по ссылке — в папке загрузки
        // и остаётся там, если не выбрать «вместе с файлами». У раздачи недокачанного нет.
        var videos = 0, partial = 0, seeding = 0
        for item in items {
            switch item {
            case .video(let j): if j.isRunning || j.state == .paused { videos += 1 }
            case .torrent(let j):
                if j.state == .downloading || j.state == .paused { partial += 1 }
                if j.state == .seeding { seeding += 1 }
            }
        }
        if videos > 0 { text += "\n\nАктивные загрузки видео остановятся, недокачанное удалится." }
        if partial > 0 {
            text += "\n\n" + (partial == 1 ? "Недокачанный торрент или файл останется" : "Недокачанные торренты и файлы останутся")
                + " в папке загрузки, если не выбрать «вместе с файлами»."
        }
        if seeding > 0 { text += "\n\n" + (seeding == 1 ? "Раздача остановится." : "Раздачи остановятся.") }
        let buttons = hasFiles ? ["Удалить из списка", "Удалить вместе с файлами", "Отмена"] : ["Удалить из списка", "Отмена"]
        let answer = Ask.run(items.count == 1 ? "Удалить «\(items[0].title)» из списка?"
                                              : "Удалить из списка загрузки: \(items.count)?",
                             text, buttons: buttons)
        guard answer != buttons.count - 1 else { return false }
        let withFiles = hasFiles && answer == 1
        let fm = FileManager.default
        for item in items {
            switch item {
            case .video(let job):
                if job.isRunning || job.state == .paused { job.cancel() }
                if withFiles, let path = item.filePath {
                    try? fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                }
                DownloadManager.shared.remove(job)
            case .torrent(let job):
                if job.isActive || job.state == .paused {
                    job.discard(trashFiles: withFiles)
                } else if withFiles, !job.filesDeleted, fm.fileExists(atPath: job.target) {
                    try? fm.trashItem(at: URL(fileURLWithPath: job.target), resultingItemURL: nil)
                }
                TorrentManager.shared.remove(job)
            }
        }
        return true
    }
}
