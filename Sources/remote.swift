import SwiftUI
import AppKit
import Network
import SystemConfiguration

// MARK: - Куда отправить ссылку

/// Ссылка из поля ввода или с iPhone: magnet — торрент, файл — aria2c, остальное — yt-dlp.
enum LinkRouter {
    /// false — не хватает компонентов: открыто окно «Компоненты».
    @MainActor
    static func submit(_ link: String, mode: Mode? = nil, origin: String) async -> Bool {
        let setup = Setup.shared, torrents = TorrentManager.shared
        if link.lowercased().hasPrefix("magnet:?") {
            torrents.enqueue(magnet: link, origin: origin)
            NSApp.activate()  // окно выбора файлов торрента — на Mac
            return true
        }
        // Ролик из плейлиста, вставленный в поле: спросить (с iPhone не спрашиваем — человек не у Mac).
        if origin == "field", let list = Playlist.watchList(link) {
            switch Ask.run("Это видео из плейлиста", "Скачать только его или весь плейлист?",
                           buttons: ["Только это видео", "Весь плейлист", "Отмена"]) {
            case 1:
                guard setup.canDownload else { setup.showSheet = true; return false }
                DownloadManager.shared.download(url: list, mode: mode, origin: origin)
                return true
            case 2: return true
            default: break
            }
        }
        let folder = UserDefaults.standard.string(forKey: "folder") ?? NSHomeDirectory() + "/Downloads"
        switch await FileLink.detect(link) {
        case .file(let info):
            guard torrents.ready() else { setup.showSheet = true; return false }
            torrents.add(file: info, folder: folder, origin: origin)
        case .video:
            guard setup.canDownload else { setup.showSheet = true; return false }
            DownloadManager.shared.download(url: link, mode: mode, origin: origin)
        }
        return true
    }

    /// Все ссылки из текста по порядку, без повторов: http(s) и magnet.
    static func allLinks(in text: String) -> [String] {
        var found: [(Int, String)] = []
        let ns = text as NSString
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let u = m.url, ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else { continue }
                found.append((m.range.location, ns.substring(with: m.range)))
            }
        }
        // magnet детектор не знает; ссылка — до пробела или конца строки
        if let re = try? NSRegularExpression(pattern: #"magnet:\?\S+"#, options: .caseInsensitive) {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                found.append((m.range.location, ns.substring(with: m.range)))
            }
        }
        var seen = Set<String>()
        return found.sorted { $0.0 < $1.0 }.map(\.1).filter { seen.insert($0).inserted }
    }

    /// Из текста, которым поделились («Смотри: https://…»), — первая ссылка.
    static func firstLink(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("magnet:?") { return t }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let match = detector?.firstMatch(in: t, range: NSRange(t.startIndex..., in: t))
        guard let url = match?.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url.absoluteString
    }
}

// MARK: - Ссылки с iPhone по домашней сети

/// Команда на iPhone («Поделиться» → DownMax) отправляет ссылку POST-запросом на
/// http://<имя-Mac>.local:47863/<ключ> с JSON {"url": …}. Ключ в адресе — единственная защита,
/// поэтому приёмник по умолчанию выключен и умеет только одно: поставить ссылку на скачивание.
final class RemoteReceiver: ObservableObject {
    static let shared = RemoteReceiver()
    static let port: UInt16 = 47863

    @Published private(set) var running = false
    @Published private(set) var error: String?
    private var listener: NWListener?

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "remoteEnabled") }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "remoteEnabled")
            newValue ? start() : stop()
        }
    }

    /// Случайный ключ, создаётся один раз; «Новый адрес» его меняет (старая команда перестаёт работать).
    var key: String {
        if let k = UserDefaults.standard.string(forKey: "remoteKey") { return k }
        return renewKey()
    }

    @discardableResult
    func renewKey() -> String {
        let letters = Array("abcdefghijkmnpqrstuvwxyz23456789")
        let k = String((0..<16).map { _ in letters.randomElement()! })
        objectWillChange.send()
        UserDefaults.standard.set(k, forKey: "remoteKey")
        return k
    }

    /// «Имя-Mac.local» — так iPhone находит Mac в домашней сети без IP-адреса.
    var host: String {
        let name = SCDynamicStoreCopyLocalHostName(nil) as String? ?? "mac"
        return name + ".local"
    }

    var address: String { "http://\(host):\(Self.port)/\(key)" }

    func startIfEnabled() { if enabled { start() } }

    private func start() {
        guard listener == nil else { return }
        _ = key  // создать ключ заранее, а не в потоке приёма
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready: self?.running = true; self?.error = nil
                    case .failed(let e):
                        self?.running = false
                        self?.error = "Не удалось принимать ссылки: \(e.localizedDescription)"
                        self?.listener = nil
                    case .cancelled: self?.running = false
                    default: break
                    }
                }
            }
            l.start(queue: .global(qos: .utility))
            listener = l
        } catch {
            self.error = "Не удалось принимать ссылки: \(error.localizedDescription)"
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    // Один запрос на соединение; принимаются только небольшие запросы.
    private func serve(_ c: NWConnection) {
        c.start(queue: .global(qos: .utility))
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self else { return c.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Request(buffer) {
                self.handle(request, from: c)
            } else if done || error != nil || buffer.count > 64 * 1024 {
                self.reply(c, 400, "Неполный запрос")
            } else {
                self.receive(c, buffer: buffer)
            }
        }
    }

    private func handle(_ r: Request, from c: NWConnection) {
        let path = r.path.split(separator: "?").first.map(String.init) ?? r.path
        guard path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == key else {
            return reply(c, 403, "Неверный адрес DownMax. Скопируйте адрес заново в «Компонентах» на Mac.")
        }
        // Тело — JSON {"url": …} из команды или просто текст со ссылкой.
        let json = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]
        let text = (json?["url"] as? String) ?? String(decoding: r.body, as: UTF8.self)
        guard let link = LinkRouter.firstLink(in: text) else {
            return reply(c, 400, "В том, что пришло, нет ссылки.")
        }
        var sender = "iPhone"
        if case .hostPort(let host, _) = c.endpoint { sender += " \(host)" }
        DispatchQueue.main.async {
            if let u = URL(string: link) { Inbox.shared.log("с iPhone", u, sender) }
            Task { @MainActor in _ = await LinkRouter.submit(link, origin: "iphone") }
        }
        reply(c, 200, "Скачиваю на Mac")
    }

    private func reply(_ c: NWConnection, _ status: Int, _ text: String) {
        let body = Data(text.utf8)
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    /// Разбор HTTP-запроса: nil, пока он пришёл не целиком.
    private struct Request {
        let path: String
        let body: Data

        init?(_ data: Data) {
            guard let end = data.range(of: Data("\r\n\r\n".utf8)),
                  let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
            let lines = head.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ") ?? []
            guard parts.count >= 2 else { return nil }
            let length = lines.dropFirst().compactMap { line -> Int? in
                let kv = line.split(separator: ":", maxSplits: 1)
                guard kv.count == 2, kv[0].lowercased() == "content-length" else { return nil }
                return Int(kv[1].trimmingCharacters(in: .whitespaces))
            }.first ?? 0
            let body = data[end.upperBound...]
            guard body.count >= length else { return nil }
            path = String(parts[1])
            self.body = Data(body.prefix(length))
        }
    }
}

// MARK: - Готовая команда для iPhone

/// Команда «DownMax» для приложения «Команды»: принимает ссылку из «Поделиться» (без ввода — из буфера
/// обмена), отправляет её POST-запросом на адрес Mac и показывает ответ уведомлением. Файл подписывает
/// `shortcuts sign`; для этого на Mac должна быть включена синхронизация «Команд» в iCloud.
enum ShortcutFile {
    static func make(address: String) throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DownMax-shortcut")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unsigned = folder.appendingPathComponent("unsigned.shortcut")
        let signed = folder.appendingPathComponent("DownMax.shortcut")
        try PropertyListSerialization.data(fromPropertyList: workflow(address), format: .binary, options: 0)
            .write(to: unsigned)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["sign", "--mode", "anyone", "--input", unsigned.path, "--output", signed.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: signed.path) else {
            let reason = output.contains("iCloud")
                ? "macOS подписывает команды, только когда у «Команд» включена синхронизация iCloud (Системные настройки → Аккаунт Apple → iCloud → «Сохранено в iCloud» → «См. все» → «Команды»)."
                : output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "DownMax", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        return signed
    }

    private static func workflow(_ address: String) -> [String: Any] {
        let object = "\u{FFFC}"  // место переменной в тексте команды
        func text(_ s: String) -> [String: Any] {
            ["Value": ["string": s], "WFSerializationType": "WFTextTokenString"]
        }
        func variable(_ attachment: [String: Any]) -> [String: Any] {
            ["Value": ["string": object, "attachmentsByRange": ["{0, 1}": attachment]], "WFSerializationType": "WFTextTokenString"]
        }
        let request = UUID().uuidString
        return [
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowClientVersion": "2605.0.5",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 61440],
            "WFWorkflowTypes": ["ActionExtension"],
            "WFWorkflowInputContentItemClasses": ["WFURLContentItem", "WFStringContentItem", "WFSafariWebPageContentItem"],
            "WFWorkflowOutputContentItemClasses": [String](),
            "WFWorkflowHasShortcutInputVariables": true,
            "WFWorkflowNoInputBehavior": ["Name": "WFWorkflowNoInputBehaviorGetClipboard", "Parameters": [String: Any]()],
            "WFWorkflowImportQuestions": [Any](),
            "WFQuickActionSurfaces": [Any](),
            "WFWorkflowActions": [
                ["WFWorkflowActionIdentifier": "is.workflow.actions.downloadurl",
                 "WFWorkflowActionParameters": [
                    "UUID": request,
                    "WFURL": address,
                    "WFHTTPMethod": "POST",
                    "WFHTTPBodyType": "JSON",
                    "ShowHeaders": false,
                    "WFJSONValues": ["Value": ["WFDictionaryFieldValueItems": [
                        ["WFItemType": 0, "WFKey": text("url"), "WFValue": variable(["Type": "ExtensionInput"])],
                    ]], "WFSerializationType": "WFDictionaryFieldValue"],
                 ] as [String: Any]],
                ["WFWorkflowActionIdentifier": "is.workflow.actions.notification",
                 "WFWorkflowActionParameters": [
                    "WFNotificationActionTitle": "DownMax",
                    "WFNotificationActionBody": variable(["Type": "ActionOutput", "OutputUUID": request, "OutputName": "Содержимое URL"]),
                    "WFNotificationActionSound": false,
                 ] as [String: Any]],
            ],
        ]
    }
}

// MARK: - Строка в «Компонентах»

struct RemoteRow: View {
    @ObservedObject var receiver = RemoteReceiver.shared
    @State private var showHelp = false
    @State private var copied = false
    @State private var making = false
    @State private var shortcutError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "iphone.and.arrow.forward")
                    .foregroundStyle(receiver.running ? .green : .secondary)
                    .font(.title3)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ссылки с iPhone").font(.headline)
                    Text("«Поделиться» на iPhone → скачивание на этом Mac")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { receiver.enabled }, set: { receiver.enabled = $0 }))
                    .toggleStyle(.switch)
                    .tint(.brand)
                    .labelsHidden()
            }
            if let error = receiver.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if receiver.enabled {
                HStack(spacing: 8) {
                    Text(receiver.address)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(copied ? "Скопировано" : "Скопировать адрес") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(receiver.address, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                    Button(making ? "Готовлю…" : "Отправить на iPhone", action: sendShortcut)
                        .disabled(making)
                        .popover(isPresented: $showHelp, arrowEdge: .bottom) { help.frame(width: 440).padding(4) }
                }
                if let shortcutError {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("Готовую команду сделать не вышло: \(shortcutError)")
                        Button("Собрать вручную") { showHelp = true }.buttonStyle(.brandLink)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Color.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Color.hairline))
    }

    /// Собрать и подписать команду, отправить по AirDrop (если его нет — показать файл в Finder).
    private func sendShortcut() {
        making = true
        shortcutError = nil
        let address = receiver.address
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ShortcutFile.make(address: address) }
            DispatchQueue.main.async {
                making = false
                switch result {
                case .success(let file):
                    if let airDrop = NSSharingService(named: .sendViaAirDrop), airDrop.canPerform(withItems: [file]) {
                        airDrop.perform(withItems: [file])
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                case .failure(let error):
                    shortcutError = error.localizedDescription
                }
            }
        }
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("На iPhone, в приложении «Команды»:")
            Text("1. «+» → назовите команду «DownMax».")
            Text("2. Добавьте действие «Получить содержимое URL». В поле URL вставьте адрес выше: нажмите здесь «Скопировать адрес», и на iPhone он вставится из общего буфера обмена.")
            Text("3. В этом действии раскройте «Показать больше»: Метод — POST, Текст запроса — JSON, «Добавить новое поле» → Текст, ключ url, значение — переменная «Ввод команды».")
            Text("4. Добавьте действие «Показать уведомление» и вставьте в него «Содержимое URL». Так iPhone покажет, принял ли DownMax ссылку.")
            Text("5. В настройках команды (ⓘ внизу) включите «Показать в меню „Поделиться“». Там же в «Если нет ввода» выберите «Вставить из буфера». Тогда команда возьмёт скопированную ссылку.")
            Text("Теперь в Threads, YouTube или Safari нажмите «Поделиться» → DownMax. Mac должен быть включён, не спать и быть в той же сети Wi-Fi.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
    }
}
