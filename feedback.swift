import SwiftUI
import AppKit

// MARK: - Панели «Поддержать» и «Оценить»

/// Всплывают над своей кнопкой внизу главного окна (со стрелкой к ней). Из меню — сначала открывается
/// главное окно. Щелчок мимо закрывает панель, но не когда в отзыве уже что-то написано (`keepOpen`).
enum FeedbackPopover {
    private static var anchors: [String: () -> NSView?] = [:]
    private static var popover: NSPopover?
    private static let delegate = Delegate()
    /// true — щелчок мимо панель не закрывает (в отзыве есть текст). Крестик и Esc закрывают всегда.
    static var keepOpen = false

    static func register(_ id: String, _ view: @escaping () -> NSView?) { anchors[id] = view }
    static var isOpen: Bool { popover?.isShown == true }

    static func show<V: View>(_ id: String, _ content: @escaping (@escaping () -> Void) -> V) {
        close()
        guard let anchor = anchors[id]?(), anchor.window?.isVisible == true else {
            // Окно закрыто: открываем его и показываем панель, когда кнопка появится на экране.
            (NSApp.delegate as? AppDelegate)?.showMainWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let a = anchors[id]?(), a.window?.isVisible == true { present(content, at: a) }
            }
            return
        }
        present(content, at: anchor)
    }

    static func close() {
        popover?.close()
        popover = nil
        keepOpen = false
    }

    private static func present<V: View>(_ content: (@escaping () -> Void) -> V, at anchor: NSView) {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.delegate = delegate
        // Размер задаёт содержимое через onGeometryChange: sizingOptions у NSHostingController на форме
        // со звёздами и TextEditor зацикливали раскладку (NSGenericException «more Update Constraints
        // in Window passes») и роняли приложение.
        let root = content(close)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                DispatchQueue.main.async {
                    if size.width > 0, size.height > 0, p.contentSize != size { p.contentSize = size }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.popover)  // без просвечивания обоев; светлее окна, чтобы не сливаться
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let controller = NSViewController()
        controller.view = host
        p.contentViewController = controller
        p.contentSize = host.fittingSize
        popover = p
        NSApp.activate()
        p.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private final class Delegate: NSObject, NSPopoverDelegate {
        func popoverShouldClose(_ popover: NSPopover) -> Bool { !FeedbackPopover.keepOpen }
        func popoverDidClose(_ notification: Notification) {
            if (notification.object as? NSPopover) === FeedbackPopover.popover {
                FeedbackPopover.popover = nil
                FeedbackPopover.keepOpen = false
            }
        }
    }
}

/// Невидимая подложка под кнопкой: запоминает её NSView, чтобы к ней привязать панель.
struct PopoverAnchor: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        FeedbackPopover.register(id) { [weak view] in view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Крестик в правом верхнем углу панели; Esc — то же самое.
struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: Metrics.radius(24)).fill(Color.primary.opacity(hovering ? 0.1 : 0.05)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(.cancelAction)
        .help("Закрыть")
    }
}

/// Кнопка с розовой обводкой: «♥ Поддержать DownMax». Под курсором — лёгкая розовая заливка.
private struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration)
    }

    private struct Label: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.brandLink)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.large)
                .background(RoundedRectangle(cornerRadius: Metrics.radius(Metrics.large))
                    .fill(Color.brand.opacity(configuration.isPressed ? 0.16 : hovering ? 0.08 : 0)))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radius(Metrics.large)).strokeBorder(Color.brand, lineWidth: 1.5))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Поддержать

enum Donate {
    static let url = URL(string: "https://pay.cloudtips.ru/p/f46d5416")!
    /// Откуда открыли «Поддержать» (window, menu, menubar) — для статистики: открыл панель → перешёл на сайт.
    private static var source = "window"

    static func open(from: String? = nil) {
        Stats.send("donate_click", ["source": from ?? source])
        NSWorkspace.shared.open(url)
    }

    static func showWindow(from: String) {
        source = from
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: DonateButton.openedKey)
        Stats.send("donate_open", ["source": from])
        FeedbackPopover.show("support") { SupportView(close: $0) }
    }
}

/// «♥ Поддержать» внизу окна. Сердце розовое и бьётся всегда («тук-тук», пауза). Раз в 2 минуты кнопка ещё и зовёт:
/// игриво покачивается и подпрыгивает — «я тут». Не зовёт под курсором, при открытой панели, в неактивном окне
/// и 7 дней после того, как панель «Поддержать» открывали. При «Уменьшить движение» не двигается ничего.
struct DonateButton: View {
    static let openedKey = "donateOpened"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beat = 0
    @State private var hovering = false

    /// Покачивание кнопки: наклон и подскок.
    private struct Wiggle { var angle = 0.0; var lift = 0.0 }

    var body: some View {
        Button { Donate.showWindow(from: "window") } label: {
            Label {
                Text("Поддержать")
            } icon: {
                HeartIcon(beating: !reduceMotion)
            }
        }
        .buttonStyle(.brandLink)  // и слово розовое, не только сердце (просьба пользователя)
        .keyframeAnimator(initialValue: Wiggle(), trigger: beat) { view, w in
            view.rotationEffect(.degrees(w.angle), anchor: .bottom).offset(y: w.lift)
        } keyframes: { _ in
            KeyframeTrack(\.angle) {
                CubicKeyframe(-6, duration: 0.1)
                CubicKeyframe(6, duration: 0.14)
                CubicKeyframe(-5, duration: 0.14)
                CubicKeyframe(4, duration: 0.14)
                CubicKeyframe(-2, duration: 0.14)
                CubicKeyframe(0, duration: 0.2)
            }
            KeyframeTrack(\.lift) {
                CubicKeyframe(-3, duration: 0.12)
                CubicKeyframe(0, duration: 0.14)
                CubicKeyframe(-2, duration: 0.12)
                CubicKeyframe(0, duration: 0.16)
            }
        }
        .onHover { hovering = $0 }
        .task {
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                if shouldBeat && !reduceMotion { beat += 1 }
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    private var shouldBeat: Bool {
        let opened = UserDefaults.standard.double(forKey: Self.openedKey)
        return NSApp.isActive && !hovering && !FeedbackPopover.isOpen
            && Date().timeIntervalSince1970 - opened > 7 * 24 * 3600
    }
}

/// Сердце, которое бьётся всегда: слой Core Animation, а не SwiftUI. Анимация SwiftUI перерисовывала окно
/// каждый кадр — 30% процессора; анимацию слоя крутит система, приложению это почти ничего не стоит.
/// Всегда залитое и розовое: живое сердце не бывает пустым (решение пользователя).
private struct HeartIcon: NSViewRepresentable {
    let beating: Bool

    func makeNSView(context: Context) -> HeartView { HeartView() }

    func updateNSView(_ view: HeartView, context: Context) {
        view.beating = beating
        view.refresh()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HeartView, context: Context) -> CGSize? {
        CGSize(width: 16, height: 16)
    }

    final class HeartView: NSView {
        var beating = true
        private let heart = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            heart.contentsGravity = .resizeAspect
            layer?.addSublayer(heart)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            heart.frame = bounds
            CATransaction.commit()
            heart.contentsScale = window?.backingScaleFactor ?? 2
        }

        override func viewDidChangeEffectiveAppearance() { refresh() }
        override func viewDidMoveToWindow() { refresh() }

        func refresh() {
            var image: NSImage?
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.brand]))
                image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(config)
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            heart.contents = image
            CATransaction.commit()

            if beating && heart.animation(forKey: "beat") == nil {
                let beat = CAKeyframeAnimation(keyPath: "transform.scale")
                // Удар, слабый следом, пауза — ~50 ударов в минуту.
                beat.values = [1, 1.2, 0.97, 1.1, 1, 1]
                beat.keyTimes = [0, 0.08, 0.18, 0.26, 0.42, 1]
                beat.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 5)
                beat.duration = 1.2
                beat.repeatCount = .infinity
                beat.isRemovedOnCompletion = false
                heart.add(beat, forKey: "beat")
            } else if !beating {
                heart.removeAnimation(forKey: "beat")
            }
        }
    }
}

private struct SupportView: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: Color.brand.opacity(0.55), radius: 28)
                .padding(.top, 8)
                .padding(.bottom, 20)
            Text("Спасибо, что пользуетесь DownMax")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text("Я делаю его один, в свободное время. Он бесплатный, без рекламы и таким останется. Если DownMax вам пригодился, поддержите: так у меня остаётся время на новые версии.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Button {
                Donate.open()
            } label: {
                Text("♥ Поддержать DownMax")
            }
            .buttonStyle(OutlineButtonStyle())
            .padding(.top, 22)
            // Версии и «Что нового» здесь нет: они в нижней строке окна (решение пользователя)
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 28)
        .frame(width: 380)
        .overlay(alignment: .topTrailing) { CloseButton(action: close).padding(12) }
    }
}

// MARK: - Оценить

/// Отзыв уходит письмом через Web3Forms (форма пользователя, письма — автору). Адрес автора в приложении
/// не хранится и не показывается; ответить можно на почту, которую человек указал сам (replyto).
/// Из curl Web3Forms не принимает (Cloudflare), из URLSession — принимает.
enum Feedback {
    private static let accessKey = "d673f0b7-db07-4ac5-abfd-459d6202744c"
    private static let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/DownMax.log")

    static func showWindow() { FeedbackPopover.show("rate") { RateView(close: $0) } }

    static func stars(_ n: Int) -> String {
        String(repeating: "★", count: n) + String(repeating: "☆", count: 5 - n)
    }

    /// Возвращает nil, если отправилось, иначе — текст ошибки.
    static func send(rating: Int, text: String, email: String, attach: [ListItem]) async -> String? {
        let version = Updater.shared.current
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "Apple Silicon"
        #else
        let arch = "Intel"
        #endif
        var message = "Оценка: \(stars(rating)) (\(rating) из 5)\n\n"
        message += text.isEmpty ? "(без текста)" : text
        message += "\n\n—\nDownMax \(version), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(arch)"
        if SafariExtension.isBundled { message += ", сборка с Safari" }
        for item in attach { message += "\n\n" + report(item) }

        var fields: [String: String] = [
            "access_key": accessKey,
            "subject": "DownMax \(stars(rating)) — \(version)",
            "from_name": "DownMax",
            "message": message,
        ]
        if !email.isEmpty {
            fields["email"] = email
            fields["replyto"] = email
        }
        var request = URLRequest(url: URL(string: "https://api.web3forms.com/submit")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: fields)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if json?["success"] as? Bool == true { return nil }
            return (json?["message"] as? String) ?? "сервер не принял отзыв"
        } catch {
            return "нет связи с сервером"
        }
    }

    /// Сведения об одной загрузке, на которую жалуются: что это, откуда, чем кончилось, и строки журнала только
    /// про её ссылку. Раньше прикладывался хвост журнала целиком — длинно и непонятно, о какой загрузке речь.
    static func report(_ item: ListItem) -> String {
        let date = DateFormatter()
        date.locale = Locale(identifier: "ru_RU")
        date.dateFormat = "d MMM yyyy, HH:mm"
        var lines = ["Загрузка, о которой отзыв:"]
        var links: [String] = []
        switch item {
        case .video(let job):
            lines.append("Название: \(job.title)")
            lines.append("Источник: \(job.sourceName) · \(job.modeText)")
            lines.append("Ссылка: \(job.url)")
            if let page = job.page { lines.append("Страница: \(page)"); links.append(page) }
            links.append(job.url)
            lines.append("Состояние: \(job.state.rawValue) — \(job.state == .done ? job.doneLine : job.detail)")
            if let raw = job.error { lines.append("Текст ошибки: \(raw)") }
            if let added = job.added { lines.append("Добавлено: \(date.string(from: added))") }
            if let path = job.filePath { lines.append("Файл: \(path)\(job.fileDeleted ? " (нет на диске)" : "")") }
            if !job.arguments.isEmpty { lines.append("Параметры yt-dlp: \(job.arguments.joined(separator: " "))") }
        case .torrent(let job):
            lines.append("Название: \(job.name)")
            lines.append("Источник: \(job.sourceName)")
            if let link = job.record.link { lines.append("Ссылка: \(link)"); links.append(link) }
            if !job.isFile { lines.append("Хеш: \(job.record.hash)"); links.append(job.record.hash) }
            lines.append("Размер: \(ByteCountFormatter.string(fromByteCount: job.record.size, countStyle: .file))")
            lines.append("Состояние: \(job.state.rawValue) — \(job.detail)")
            if let raw = job.record.error { lines.append("Текст ошибки: \(raw)") }
            if let added = job.record.added { lines.append("Добавлено: \(date.string(from: added))") }
        }
        let log = logLines(matching: links)
        lines.append("")
        lines.append(log.isEmpty ? "В журнале о ней записей нет." : "Журнал (только эта загрузка):\n" + log.joined(separator: "\n"))
        return lines.joined(separator: "\n")
    }

    /// Строки журнала, где встречается одна из ссылок (в журнале они бывают закодированы — сравниваем раскодированные).
    private static func logLines(matching links: [String]) -> [String] {
        guard !links.isEmpty, let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }
        let keys = links.map { $0.lowercased() }
        return text.split(separator: "\n").map(String.init).filter { line in
            let plain = (line.removingPercentEncoding ?? line).lowercased()
            return keys.contains { plain.contains($0) }
        }.suffix(20)
    }
}

private struct RateView: View {
    let close: () -> Void
    @State private var rating = 0
    @State private var hovered = 0
    @State private var text = ""
    @State private var email = ""
    /// Отзыв длиннее не нужен, а письмо остаётся читаемым (~страница текста).
    static let textLimit = 2000
    /// Высота текста отзыва (меряется невидимой копией) — от неё высота поля.
    @State private var textHeight: CGFloat = 110
    private var showCounter: Bool { text.count >= Self.textLimit * 3 / 4 }
    /// Какие загрузки приложить к отзыву (галочки в списке).
    @State private var attachIDs: Set<UUID> = []
    @State private var sending = false
    @State private var error: String?
    @State private var sent = false
    @FocusState private var focus: Field?
    @State private var hoveredField: Field?
    /// Показать, что почта с ошибкой: после паузы в наборе (0,6 с) или когда ушли из поля — не во время набора.
    @State private var showEmailError = false
    @State private var emailCheck: Task<Void, Never>?

    private enum Field { case text, email }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Пусто — можно (почта необязательна); иначе «что-то@домен.зона», зона — от двух букв, без пробелов.
    private var emailIsValid: Bool {
        trimmedEmail.isEmpty
            || trimmedEmail.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s.]{2,}$"#, options: .regularExpression) != nil
    }
    private var placeholder: String {
        switch rating {
        case 1...3: return "Что пошло не так? Какую ссылку качали и что случилось?"
        case 4: return "Чего не хватает до пятёрки?"
        default: return "Что понравилось? Чего хотелось бы ещё?"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if sent { thanks } else { form }
        }
        // Шрифты — три размера: заголовок 15, всё содержимое 13, подсказки 12 (серые). Поля 24 по бокам и снизу (кнопка
        // внизу любит равный отступ), сверху 20 (над заголовком ещё пустота шрифта — видно ~23).
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
        .frame(width: 380)
        .animation(.easeOut(duration: 0.15), value: rating)
        .animation(.easeOut(duration: 0.15), value: sent)
        // Написанный отзыв не теряется от случайного щелчка мимо панели.
        .onChange(of: text + email) { updateKeepOpen() }
        .onChange(of: sent) { updateKeepOpen() }
    }

    private func updateKeepOpen() {
        let draft = !(text + email).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        FeedbackPopover.keepOpen = draft && !sent
    }

    private var form: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Как вам DownMax?").font(.title3.bold())
                Spacer()
                CloseButton(action: close)
            }
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { star in
                    let lit = star <= (hovered > 0 ? hovered : rating)
                    Button { rating = star } label: {
                        Image(systemName: lit ? "star.fill" : "star")
                            .font(.system(size: 30))
                            .foregroundStyle(lit ? AnyShapeStyle(Color.brand) : AnyShapeStyle(.tertiary))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? star : (hovered == star ? 0 : hovered) }
                    .help(["Плохо", "Так себе", "Нормально", "Хорошо", "Отлично"][star - 1])
                    .accessibilityLabel(Feedback.stars(star))
                }
            }
            .padding(.top, 20)
            Text(rating == 0 ? "Выберите оценку" : "Спасибо за оценку!")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            if rating > 0 { details.transition(.opacity) }
        }
    }

    /// Ступени: внутри жалобы (текст + загрузки) — 8, между группами (жалоба · почта · кнопка) — 16,
    /// от оценки до формы — 24.
    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Поле растёт с текстом: от 5 строк (110) до 12 (220), дальше прокрутка. Высоту задаёт невидимая копия
            // текста с теми же отступами. Больше 2000 символов не вводится; счётчик — только с 1500.
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.automatic)
                    .focused($focus, equals: .text)
                    .padding(.horizontal, 9)
                    .padding(.top, 10)  // от скругления текст дальше
                    .padding(.bottom, showCounter ? 28 : 10)  // под счётчиком — своя строка, текст под него не заходит
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
            // копия текста только меряет высоту (фон, не раскладывает поле); само поле — от 110 до 220 и обрезано
            .background(alignment: .top) {
                Text(text.isEmpty ? " " : text + " ")
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, showCounter ? 28 : 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
            }
            .frame(height: min(max(textHeight, 110), 220))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
            .overlay(alignment: .bottomTrailing) {
                if showCounter {
                    Text(verbatim: "\(text.count.formatted()) из \(Self.textLimit.formatted())")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(text.count >= Self.textLimit ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Color.field))
            .fieldBorder(focused: focus == .text, hovering: hoveredField == .text)
            .onHover { hoveredField = $0 ? .text : (hoveredField == .text ? nil : hoveredField) }
            .onChange(of: text) { _, new in
                if new.count > Self.textLimit { text = String(new.prefix(Self.textLimit)) }
            }

            // Загрузки прикладывают к жалобе — блок только при 1–3★, сразу под текстом «что пошло не так»
            // (при 4–5 просить «отметьте, что не работает» нелогично). Последняя неудачная отмечена сама.
            if rating <= 3 {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Приложить загрузки").fontWeight(.medium)
                    Text("Отметьте те, что не скачались. Я увижу только их ссылки, ошибки и записи журнала.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // галочками — можно отметить несколько. Строка ровно 18, шаг 10: до 6 штук — без прокрутки,
                // больше — прокрутка с видимыми 6 (высота считалась формулой и подрезала последнюю строку).
                let items = recent
                if items.isEmpty {
                    Text("Загрузок пока нет.").foregroundStyle(.secondary)
                } else if items.count <= 6 {
                    attachList(items)
                } else {
                    ScrollView { attachList(items) }
                        .frame(height: 6 * 18 + 5 * 10)
                        .thinScrollIndicator()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .fill(Color.primary.opacity(0.05)))  // нейтральная: розовая подложка на тёмном — грязная
            .transition(.opacity)
            .padding(.top, 8)  // к тексту жалобы — вплотную по смыслу
            .onAppear {
                if attachIDs.isEmpty, let failed = recent.first(where: { $0.status == .failed }) { attachIDs = [failed.id] }
            }
            }

            VStack(alignment: .leading, spacing: 6) {
            TextField("Почта для ответа (необязательно)", text: $email)
                .textFieldStyle(.plain)
                .focused($focus, equals: .email)
                .focusEffectDisabled()
                .padding(.horizontal, 14)
                .padding(.bottom, 2)  // на 1 pt выше середины: вес строчных внизу, по центру строка кажется опущенной
                .frame(height: Metrics.large)
                .background(RoundedRectangle(cornerRadius: Metrics.radius(Metrics.large)).fill(Color.field)
                    .onTapGesture { focus = .email })  // вся плашка ставит курсор, не только строка текста
                .fieldBorder(focused: focus == .email, hovering: hoveredField == .email, cornerRadius: Metrics.radius(Metrics.large))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radius(Metrics.large))
                    .strokeBorder(Color.red, lineWidth: 1).opacity(showEmailError ? 1 : 0))
                .onHover { hoveredField = $0 ? .email : (hoveredField == .email ? nil : hoveredField) }
                .onChange(of: email) {
                    showEmailError = false
                    emailCheck?.cancel()
                    emailCheck = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        if !Task.isCancelled { showEmailError = !emailIsValid }
                    }
                }
                .onChange(of: focus) { _, new in if new != .email { showEmailError = !emailIsValid } }
            if showEmailError {
                Text(verbatim: "Не похоже на почту — например, name@mail.ru")  // verbatim: иначе адрес станет синей ссылкой
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.leading, 14)  // по тексту поля
                    .transition(.opacity)
            }
            }
            .padding(.top, 16)

            if let error {
                Text("Не удалось отправить: \(error). Попробуйте ещё раз.")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            Button(action: send) {
                HStack(spacing: 6) {
                    if sending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                        Text("Отправить")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.brandFill)
            .keyboardShortcut(.defaultAction)
            .disabled(sending || !emailIsValid)
            .padding(.top, 16)
        }
        .padding(.top, 24)
    }

    private var thanks: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                CloseButton(action: close)
            }
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.brand)
            Text("Отзыв отправлен")
                .font(.title3.bold())
                .padding(.top, 12)
            Text(trimmedEmail.isEmpty ? "Спасибо, что нашли время!" : "Спасибо! Отвечу на \(trimmedEmail).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            if rating >= 4 {
                Text("Если DownMax вам нравится, его можно поддержать.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)
                Button { Donate.open(from: "feedback") } label: { Text("♥ Поддержать DownMax") }
                    .buttonStyle(OutlineButtonStyle())
                    .padding(.top, 12)
            }
            Button("Закрыть", action: close)
                .controlSize(.large)
                .buttonStyle(.gray)
                .padding(.top, rating >= 4 ? 10 : 20)
        }
    }

    /// Последние загрузки для меню «Приложить загрузку» — новые сверху.
    private var recent: [ListItem] {
        Array(ListFilter.items(videos: DownloadManager.shared.jobs, torrents: TorrentManager.shared.torrents,
                               sort: .newest, status: .all, source: "").prefix(20))
    }

    private func attachList(_ items: [ListItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                Toggle(isOn: attachBinding(item.id)) {
                    HStack(spacing: 4) {
                        if item.status == .failed {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10)).foregroundStyle(.red)
                        }
                        Text(item.title).lineLimit(1).truncationMode(.tail)  // не резать слово посередине
                    }
                }
                .toggleStyle(.brandCheckbox)
                .frame(height: 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attachBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { attachIDs.contains(id) },
                set: { if $0 { attachIDs.insert(id) } else { attachIDs.remove(id) } })
    }

    private func send() {
        guard rating > 0, emailIsValid, !sending else { return }
        sending = true
        error = nil
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let attach = rating <= 3 ? recent.filter { attachIDs.contains($0.id) } : []  // блок скрыт — не прикладываем
            let failure = await Feedback.send(rating: rating, text: text, email: trimmedEmail, attach: attach)
            if failure == nil { Stats.send("feedback", ["rating": rating]) }
            sending = false
            if let failure { error = failure } else { sent = true }
        }
    }
}
