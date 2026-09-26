import SwiftUI
import AppKit

// MARK: - Обновление из релизов GitHub

/// Раз в день (и по «Проверить обновления…») смотрит последний релиз на GitHub. «Обновить» скачивает
/// DownMax-macOS.zip, а подмена приложения делается после выхода: маленький скрипт ждёт, пока DownMax
/// закроется, кладёт новую версию на место старой и запускает её. Файл, скачанный самим приложением,
/// macOS не помечает карантином — предупреждения Gatekeeper не будет.
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "ohlexlexa/DownMax"
    static let asset = "DownMax-macOS.zip"

    struct Release {
        let version: String
        let page: URL
        let zip: URL?   // nil — в релизе нет DownMax-macOS.zip (до 2.0 архив назывался иначе)
        let notes: String  // описание релиза (markdown) — показывается в «Что нового»
    }

    @Published var available: Release?
    @Published var busy: String?
    /// Когда последний раз удалось спросить GitHub — для строки внизу окна.
    @Published private(set) var lastChecked: Date?
    /// Последняя проверка из строки внизу не удалась (нет связи, GitHub не ответил).
    @Published private(set) var failed = false
    /// Версия, до которой приложение обновилось, — показывается внизу сутки после обновления.
    @Published private(set) var updatedTo: String?
    /// «У вас последняя версия» — несколько секунд после «Проверить» в строке, чтобы было видно, что проверка прошла.
    @Published private(set) var upToDate = false

    /// Распакованная новая версия: ставится, когда приложение закрывается.
    private var staged: (app: String, folder: String)?
    private static let lastCheckKey = "lastUpdateCheck"
    private static let lastRunKey = "lastRunVersion"
    private static let updatedAtKey = "updatedAt"

    private init() {
        let d = UserDefaults.standard
        let last = d.double(forKey: Self.lastCheckKey)
        lastChecked = last > 0 ? Date(timeIntervalSince1970: last) : nil
        // Запуск после обновления: версия новее той, что запускалась прошлый раз.
        if let previous = d.string(forKey: Self.lastRunKey), Self.isNewer(current, than: previous) {
            d.set(Date().timeIntervalSince1970, forKey: Self.updatedAtKey)
        }
        d.set(current, forKey: Self.lastRunKey)
        if Date().timeIntervalSince1970 - d.double(forKey: Self.updatedAtKey) < 24 * 3600 { updatedTo = current }
    }

    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// Своя сборка с Safari обновляется пересборкой: в релизе Safari нет, обновление бы его убрало.
    var enabled: Bool { !SafariExtension.isBundled }

    func checkDaily() {
        guard enabled else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        check(manual: false)
    }

    /// manual — по пункту меню: тогда ответ показывается, даже если обновлений нет или GitHub недоступен.
    /// inline — по «Проверить» в строке внизу окна: ответ виден в самой строке, без окон.
    func check(manual: Bool, inline: Bool = false) {
        guard busy == nil else { return }
        guard enabled else {
            if manual && !inline { show("Эта сборка обновляется пересборкой",
                             "В ней есть расширение для Safari, а в релизах на GitHub его нет. Обновить: git pull и ./build.sh в папке проекта.") }
            return
        }
        if manual { busy = "Проверяю обновления"; failed = false; upToDate = false }
        let started = Date()
        // updateFeed — только для проверки обновлятора на своём Mac (адрес с таким же JSON, как у GitHub).
        let feed = UserDefaults.standard.string(forKey: "updateFeed")
            ?? "https://api.github.com/repos/\(Self.repo)/releases/latest"
        var request = URLRequest(url: URL(string: feed)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DownMax/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let release = data.flatMap(Self.parse)
            // Из строки — крутилка хотя бы 0,7 с: мгновенный ответ выглядит, будто ничего не произошло.
            let wait = inline ? max(0, 0.7 - Date().timeIntervalSince(started)) : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                if manual { self.busy = nil }
                guard let release else {
                    if inline { self.failed = true; return }
                    if manual { self.show("Не удалось проверить обновления",
                                          error?.localizedDescription ?? "GitHub не ответил. Попробуйте позже.") }
                    return
                }
                let now = Date()
                UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastCheckKey)
                self.lastChecked = now
                self.failed = false
                if Self.isNewer(release.version, than: self.current) {
                    self.available = release
                    if manual && !inline { self.offer(release) }
                } else {
                    self.available = nil
                    if inline {
                        self.upToDate = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.upToDate = false }
                    }
                    if manual && !inline { self.show("Установлена последняя версия", "DownMax \(self.current)") }
                }
            }
        }.resume()
    }

    private static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        let zip = (assets.first(where: { $0["name"] as? String == asset })?["browser_download_url"] as? String)
            .flatMap(URL.init(string:))
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page, zip: zip,
                       notes: json["body"] as? String ?? "")
    }

    /// «2.10» новее «2.9»: сравнение по числам.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if p != q { return p > q }
        }
        return false
    }

    private func offer(_ release: Release) {
        switch Ask.run("Доступна версия \(release.version)",
                       "У вас \(current). DownMax скачает обновление, перезапустится и продолжит торренты.",
                       buttons: ["Обновить", "Что нового", "Позже"]) {
        case 0: install()
        case 1: showNotes(release)
        default: break
        }
    }

    /// «Что нового» — панель над кнопкой в нижней строке, а не страница GitHub: из приложения никуда не уводим.
    func showNotes(_ release: Release) {
        FeedbackPopover.show("whatsnew") { WhatsNewView(release: release, close: $0) }
    }

    func install() {
        guard let release = available, busy == nil else { return }
        let target = Bundle.main.bundlePath
        guard let zip = release.zip else {
            NSWorkspace.shared.open(release.page)
            return
        }
        guard FileManager.default.isWritableFile(atPath: (target as NSString).deletingLastPathComponent) else {
            show("Не получится обновить", "Нет прав на запись в папку, где лежит DownMax. Скачайте новую версию со страницы релиза.")
            NSWorkspace.shared.open(release.page)
            return
        }
        busy = "Скачиваю обновление"
        // Не в Caches/DownMax: её приложение чистит при выходе, а обновление нужно именно после выхода.
        let folder = NSTemporaryDirectory() + "DownMax-update-" + release.version
        Task {
            do {
                let app = try await Self.download(release, zip: zip, into: folder)
                await MainActor.run {
                    self.busy = nil
                    self.staged = (app, folder)
                    NSApp.terminate(nil)  // сама подмена — в installOnQuit()
                }
            } catch {
                await MainActor.run {
                    self.busy = nil
                    try? FileManager.default.removeItem(atPath: folder)
                    self.show("Не удалось обновить", error.localizedDescription)
                }
            }
        }
    }

    private static func download(_ release: Release, zip url: URL, into folder: String) async throws -> String {
        let fm = FileManager.default
        try? fm.removeItem(atPath: folder)
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let (file, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw failure("GitHub ответил \(http.statusCode)")
        }
        let zip = folder + "/" + asset
        try fm.moveItem(at: file, to: URL(fileURLWithPath: zip))
        guard run("/usr/bin/ditto", ["-x", "-k", zip, folder]) else { throw failure("архив не распаковался") }
        let app = folder + "/DownMax.app"
        // Это точно DownMax той версии, что обещал релиз, и подпись цела.
        guard let bundle = Bundle(path: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.infoDictionary?["CFBundleShortVersionString"] as? String == release.version else {
            throw failure("в архиве не та версия приложения")
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", app]) else { throw failure("подпись приложения повреждена") }
        return app
    }

    /// Вызывается из applicationWillTerminate. Старая версия откладывается в сторону и возвращается,
    /// если новую положить не удалось.
    func installOnQuit() {
        guard let (app, folder) = staged else { return }
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        if mv "$2" "$4/old.app" && /usr/bin/ditto "$3" "$2"; then rm -rf "$4/old.app"
        else rm -rf "$2"; mv "$4/old.app" "$2"; fi
        open "$2"
        rm -rf "$4"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "downmax-update", String(ProcessInfo.processInfo.processIdentifier),
                       Bundle.main.bundlePath, app, folder]
        try? p.run()
    }

    private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func failure(_ text: String) -> Error {
        NSError(domain: "DownMax", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private func show(_ title: String, _ text: String) {
        Ask.run(title, text)
    }
}

/// Строка внизу окна — состояние обновлений видно всегда:
/// «Версия 2.0 · проверено сегодня в 14:30  Проверить», «Проверяю…», «Доступна версия 2.1  Обновить  Что нового»,
/// «Обновлено до 2.1» (сутки после обновления), «Не удалось проверить  Повторить». Сборка с Safari обновляется
/// пересборкой — у неё только «Версия 2.0 · своя сборка».
struct UpdateBar: View {
    @ObservedObject var updater: Updater

    var body: some View {
        HStack(spacing: 8) {
            if let busy = updater.busy {
                ProgressView().controlSize(.mini)
                Text(busy + "…").foregroundStyle(.secondary)
            } else if let release = updater.available {
                Text("Доступна версия \(release.version)").foregroundStyle(.secondary)
                Button("Обновить", action: updater.install).buttonStyle(.brandFill).controlSize(.small)
                Button("Что нового") { updater.showNotes(release) }
                    .buttonStyle(.brandLink)
                    .background(PopoverAnchor(id: "whatsnew"))
            } else if !updater.enabled {
                Text("Версия \(updater.current) · своя сборка").foregroundStyle(.secondary)
                    .help("В этой сборке есть расширение для Safari — она обновляется пересборкой, а не из релизов")
            } else if updater.upToDate {
                Label {
                    Text("У вас последняя версия \(updater.current)").foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)  // зелёный, как «Всё готово» слева
                }
                .transition(.opacity)
            } else if updater.failed {
                Text("Не удалось проверить обновления").foregroundStyle(.secondary)
                check("Повторить")
            } else {
                // Раз в минуту — чтобы «сегодня» после полуночи стало «вчера».
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(status(now: context.date)).foregroundStyle(.secondary)
                }
                check("Проверить")
            }
        }
        .font(.callout)
        .lineLimit(1)
        .animation(.easeOut(duration: 0.2), value: updater.upToDate)
        .frame(height: Metrics.small)  // как у кнопки «Обновить» — полоса не прыгает, когда она появляется
        // Окно может висеть открытым днями: раз в час смотрим, не пора ли проверить (сама проверка — раз в сутки).
        .onReceive(Timer.publish(every: 3600, on: .main, in: .common).autoconnect()) { _ in updater.checkDaily() }
    }

    private func check(_ title: String) -> some View {
        Button { updater.check(manual: true, inline: true) } label: { Label(title, systemImage: "arrow.clockwise") }
            .buttonStyle(.quiet)
            .help("Проверить, нет ли новой версии DownMax")
    }

    private func status(now: Date) -> String {
        if let version = updater.updatedTo { return "Обновлено до \(version)" }
        guard let date = updater.lastChecked else { return "Версия \(updater.current)" }
        return "Версия \(updater.current) · проверено \(Self.when(date, now: now))"
    }

    /// «сегодня в 14:30», «вчера в 9:05», «24 сентября».
    static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "H:mm"
        if calendar.isDate(date, inSameDayAs: now) { return "сегодня в " + f.string(from: date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "вчера в " + f.string(from: date)
        }
        f.dateFormat = "d MMMM"
        return f.string(from: date)
    }
}

/// Панель «Что нового в 2.1»: описание релиза с GitHub и кнопка «Обновить». Описание — markdown; показывается
/// до раздела «Установка…» — он для тех, кто скачивает архив руками, а не обновляется из приложения.
struct WhatsNewView: View {
    let release: Updater.Release
    let close: () -> Void
    @State private var height: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Что нового в \(release.version)")
                .font(.title3.bold())
                .padding(.trailing, 32)  // место под крестик
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if blocks.isEmpty {
                        Text("Описания изменений нет.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .heading(let text):
                            Text(text).font(.body.weight(.semibold)).padding(.top, 4)
                        case .item(let text):
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(.secondary)
                                Text(text)
                            }
                        case .text(let text):
                            Text(text)
                        }
                    }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .frame(height: min(max(height, 20), 360))  // длинное описание прокручивается
            .thinScrollIndicator()
            .padding(.top, 12)
            HStack(spacing: 8) {
                Spacer()
                Button("Позже", action: close).buttonStyle(.gray)
                Button("Обновить") { close(); Updater.shared.install() }.buttonStyle(.brandFill)
            }
            .controlSize(.large)
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 420)
        .overlay(alignment: .topTrailing) { CloseButton(action: close).padding(12) }
    }

    private enum Block { case heading(AttributedString), item(AttributedString), text(AttributedString) }

    private var blocks: [Block] {
        var result: [Block] = []
        for raw in release.notes.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let plain = line.trimmingCharacters(in: CharacterSet(charactersIn: "#* "))
            if plain.hasPrefix("Установка") { break }
            if line.hasPrefix("#") {
                result.append(.heading(Self.markdown(plain)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result.append(.item(Self.markdown(String(line.dropFirst(2)))))
            } else {
                result.append(.text(Self.markdown(line)))
            }
        }
        return result
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
