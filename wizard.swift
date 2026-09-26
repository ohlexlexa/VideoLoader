import SwiftUI

// MARK: - Мастер первого запуска

/// Отдельное окно при первом запуске: по одному действию на экран, «Назад» и «Пропустить» везде.
/// Тем, кто обновляется с прежних версий, сам не показывается; снова — меню DownMax → «Помощник настройки…».
enum Wizard {
    private static let doneKey = "wizardDone"
    private static var window: NSWindow?
    private static var onFinish: (() -> Void)?
    private static let closer = Closer()

    /// Вызывать до `OldName.migrate()`: новый ли это пользователь, видно по следам прежних версий.
    static func decideOnLaunch() {
        let d = UserDefaults.standard
        guard d.object(forKey: doneKey) == nil else { return }
        let old = d.persistentDomain(forName: "local.ohlexlexa.videoloader") ?? [:]
        let usedBefore = d.bool(forKey: "migratedFromVideoLoader") || ["folder", "mode", "quality"].contains { old[$0] != nil }
        d.set(usedBefore, forKey: doneKey)
    }

    static var pending: Bool { !UserDefaults.standard.bool(forKey: doneKey) }
    static var isOpen: Bool { window != nil }

    /// then — что открыть после мастера (главное окно). Уже открыт — просто вперёд, прежнее «then» остаётся.
    static func show(then: (() -> Void)? = nil) {
        if let then { onFinish = then }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: WizardView.size.width, height: WizardView.size.height),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.backgroundColor = .surface
            w.contentViewController = NSHostingController(rootView: WizardView())
            w.isReleasedWhenClosed = false
            w.delegate = closer
            w.center()
            window = w
        }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            DockProgress.shared.showIdle()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func finish() { window?.close() }

    /// Закрыли крестиком или «Начать» — мастер пройден, дальше главное окно.
    private final class Closer: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            UserDefaults.standard.set(true, forKey: Wizard.doneKey)
            Wizard.window = nil
            let next = Wizard.onFinish
            Wizard.onFinish = nil
            DispatchQueue.main.async { next?() }
        }
    }
}

struct WizardView: View {
    static let size = CGSize(width: 680, height: 600)

    enum Step: Int, CaseIterable { case welcome, components, browser, torrents, iphone, done }

    @ObservedObject private var setup = Setup.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .welcome
    @State private var forward = true

    var body: some View {
        VStack(spacing: 0) {
            dots.padding(.top, 20)
            ZStack {
                page(step)
                    .id(step)
                    .transition(transition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 40)
            .padding(.top, 24)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color.surface)
        .buttonStyle(.gray)
        .controlSize(.large)
        .onAppear { setup.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            setup.refresh()  // вернулись из Chrome — вдруг расширение уже стоит
        }
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    private func go(_ to: Step) {
        forward = to.rawValue > step.rawValue
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 1)) { step = to }
    }

    private func next() { Step(rawValue: step.rawValue + 1).map(go) }
    private func back() { Step(rawValue: step.rawValue - 1).map(go) }

    // MARK: Точки хода и нижняя строка

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(s == step ? Color.brand : Color.primary.opacity(s.rawValue < step.rawValue ? 0.35 : 0.15))
                    .frame(width: s == step ? 20 : 8, height: 8)
            }
        }
        .animation(.easeOut(duration: 0.2), value: step)
        .accessibilityLabel("Шаг \(step.rawValue + 1) из \(Step.allCases.count)")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if step != .welcome && step != .done {
                Button("Назад", action: back)
            }
            Spacer()
            if showSkip {
                Button("Пропустить", action: next).buttonStyle(.quiet)
                    .padding(.trailing, 8)
            }
            primary
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var componentsReady: Bool { setup.checked && setup.missing.isEmpty }

    private var showSkip: Bool {
        switch step {
        case .components: !componentsReady && setup.busy == nil
        case .browser: !setup.browsers.contains(where: \.extensionInstalled) && setup.safari != .enabled
        case .iphone: true
        default: false
        }
    }

    @ViewBuilder private var primary: some View {
        switch step {
        case .welcome:
            Button("Начать", action: next).buttonStyle(.brandFill).keyboardShortcut(.defaultAction)
        case .components where !componentsReady:
            Button(setup.busy != nil ? "Скачиваю…" : "Установить", action: setup.installMissing)
                .buttonStyle(.brandFill)
                .disabled(setup.busy != nil || !setup.checked)
                .keyboardShortcut(.defaultAction)
        case .done:
            Button("Начать пользоваться", action: Wizard.finish).buttonStyle(.brandFill).keyboardShortcut(.defaultAction)
        default:
            Button("Далее", action: next).buttonStyle(.brandFill).keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Экраны

    @ViewBuilder private func page(_ step: Step) -> some View {
        switch step {
        case .welcome: welcome
        case .components: components
        case .browser: browser
        case .torrents:
            VStack(alignment: .leading, spacing: 24) {
                header(3, "Торренты", "DownMax качает торренты и magnet-ссылки. Сделайте его программой для торрентов — "
                       + "тогда ссылки из браузера сразу откроются в нём.")
                TorrentHandlerRow().controlSize(.regular)
            }
        case .iphone:
            VStack(alignment: .leading, spacing: 24) {
                header(4, "Ссылки с iPhone", "Нажмите «Поделиться» на iPhone, и видео скачается на этот Mac. "
                       + "Mac и iPhone должны быть в одной сети Wi-Fi. Можно включить и позже, в «Компонентах».")
                RemoteRow().controlSize(.regular)
            }
        case .done: done
        }
    }

    private func header(_ n: Int, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Шаг \(n) из 4").font(.callout.weight(.medium)).foregroundStyle(Color.brandLink)
            Text(title).font(.system(size: 26, weight: .semibold))
            Text(text).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appIcon: some View {
        Group {
            if let url = Bundle.main.url(forResource: "DockIcon", withExtension: "png"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "arrow.down.circle.fill").resizable().foregroundStyle(Color.brand)
            }
        }
        .frame(width: 112, height: 112)
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            appIcon
            Text("Добро пожаловать в DownMax").font(.system(size: 28, weight: .semibold))
            Text("DownMax качает видео с YouTube, VK, Instagram, TikTok и ещё двадцати сайтов, а также торренты и файлы "
                 + "по ссылкам. Настроим всё за пару минут.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var done: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.white, Color.brand)
            Text("Всё готово").font(.system(size: 28, weight: .semibold))
            Text("Скопируйте ссылку на видео, вставьте её в поле вверху окна DownMax и нажмите «Скачать».")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
            Text("Вернуться к настройке — меню DownMax → «Помощник настройки…»")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Компоненты

    private var components: some View {
        VStack(alignment: .leading, spacing: 24) {
            header(1, componentsReady ? "Всё нужное на месте" : "Программы для скачивания",
                   componentsReady ? "DownMax качает видео и торренты этими программами и сам следит, чтобы они были свежими."
                                   : "DownMax качает видео с помощью бесплатных программ. Он скачает их сам: "
                                     + "около \(setup.downloadSize) МБ, пароль не нужен.")
            VStack(spacing: 0) {
                ForEach(setup.components) { c in
                    HStack(spacing: 10) {
                        let ready = c.installed || (setup.placed.contains(c.id) && !downloading(c))
                        Image(systemName: ready ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(ready ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                            .font(.title3)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.id).font(.headline)
                            Text(c.purpose).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(c.installed ? (c.version ?? "есть") : downloading(c) ? "скачиваю…"
                             : setup.placed.contains(c.id) ? "готово" : "скачается")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    if c.id != setup.components.last?.id { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Color.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Color.hairline))

            if let progress = setup.progress {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress).tint(.brand)
                    Text("\(setup.busy ?? "") · \(Int(progress * 100))%").font(.callout).foregroundStyle(.secondary)
                }
            } else if let busy = setup.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy + "…").font(.callout).foregroundStyle(.secondary)
                }
            } else if setup.failed {
                Text(setup.log).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Сейчас качается эта программа: подпись хода — «Скачиваю ffprobe (3 из 4)», ffprobe входит в ffmpeg.
    private func downloading(_ c: Component) -> Bool {
        guard let busy = setup.busy, setup.progress != nil else { return false }
        return busy.contains(" \(c.id)") || (c.id == "ffmpeg" && busy.contains(" ffprobe"))
    }

    // MARK: Браузер

    private var browser: some View {
        VStack(alignment: .leading, spacing: 24) {
            header(2, "Кнопка «Скачать» в браузере",
                   "Расширение добавляет кнопку под видео на YouTube, VK и других сайтах. Можно и без него — "
                   + "просто вставляйте ссылку в DownMax.")
            if setup.browsers.isEmpty && setup.safari == .absent {
                Text("Google Chrome на этом Mac не нашёлся. Ничего страшного: ссылки можно вставлять прямо в DownMax.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    if setup.safari != .absent {
                        browserRow("safari", "Safari", installed: setup.safari == .enabled,
                                   button: "Включить в Safari", action: SafariExtension.openSettings)
                        if !setup.browsers.isEmpty { Divider() }
                    }
                    ForEach(setup.browsers, id: \.id) { state in
                        browserRow("globe", state.browser.name, installed: state.extensionInstalled,
                                   button: "Установить") { setup.installExtension(in: state.browser) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Color.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Color.hairline))
            }
            if let b = setup.extensionHelpFor {
                ChromeSteps(browser: b)
            }
        }
    }

    private func browserRow(_ symbol: String, _ name: String, installed: Bool, button: String,
                            action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: installed ? "checkmark.circle.fill" : symbol)
                .foregroundStyle(installed ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .font(.title3)
                .frame(width: 22)
            Text(name).font(.headline)
            Spacer()
            if installed {
                Text("установлено").font(.callout).foregroundStyle(.secondary)
            } else {
                Button(button, action: action).controlSize(.regular)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Три шага установки расширения в Chrome — схемами, а не снимками: так понятно, куда смотреть, и не зависит от версии Chrome.
private struct ChromeSteps: View {
    let browser: Browser

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("В \(browser.nameIn) открылась страница расширений, а справа внизу экрана — подсказка с папкой. Три шага:")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                card(1, "Включите «Режим разработчика» справа вверху") { developerMode }
                card(2, "Перетащите папку DownMax с подсказки на страницу") { dragFolder }
                card(3, "Разрешите Chrome открывать DownMax") { allowDialog }
            }
        }
    }

    private func card(_ n: Int, _ text: String, @ViewBuilder mock: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            mock()
                .frame(maxWidth: .infinity)
                .frame(height: 84)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.2)))
            HStack(alignment: .top, spacing: 6) {
                Text("\(n)").font(.callout.weight(.bold)).foregroundStyle(Color.brandLink)
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toggleOn: some View {
        Capsule().fill(Color.brand).frame(width: 26, height: 15)
            .overlay(Circle().fill(.white).frame(width: 11).offset(x: 5.5))
    }

    private var developerMode: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer()
                Text("Режим разработчика").font(.system(size: 9)).foregroundStyle(.secondary).fixedSize()
                toggleOn
                    .padding(3)
                    .overlay(Capsule().strokeBorder(Color.brand.opacity(0.6), lineWidth: 1.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            HStack {
                Text("Расширения").font(.system(size: 10, weight: .semibold)).fixedSize()
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            Spacer()
        }
    }

    private var dragFolder: some View {
        HStack(spacing: 10) {
            VStack(spacing: 2) {
                Image(systemName: "folder.fill").font(.system(size: 26)).foregroundStyle(Color(red: 0.35, green: 0.62, blue: 0.95))
                Text("DownMax").font(.system(size: 8))
            }
            Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.brand)
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: 60, height: 48)
                .overlay(Text("страница\nрасширений").font(.system(size: 8)).multilineTextAlignment(.center).foregroundStyle(.secondary))
        }
    }

    private var allowDialog: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Открыть «DownMax»?").font(.system(size: 10, weight: .semibold))
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3).fill(Color.brand).frame(width: 11, height: 11)
                    .overlay(Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white))
                Text("Всегда разрешать").font(.system(size: 9))
            }
            HStack {
                Spacer()
                Text("Открыть").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.brand))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.28)))
        .padding(.horizontal, 12)
    }
}

// MARK: - Подсказка поверх Chrome

/// Панель у правого нижнего края экрана поверх всех окон, пока ставится расширение: Chrome открывается на весь экран
/// и перекрывает всё, новичок терялся. Папку расширения тащат прямо с панели — Finder не нужен. Панель не забирает
/// фокус у Chrome (nonactivating) и не прячется, когда DownMax не активен. Когда расширение отозвалось
/// (downmax://installed) — «Готово» и закрывается сама.
enum ExtensionHelper {
    private static var panel: NSPanel?

    static func show(for browser: Browser) {
        let size = NSSize(width: 320, height: 430)
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isFloatingPanel = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.backgroundColor = .surface
            p.isReleasedWhenClosed = false
            p.isMovableByWindowBackground = true
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                p.standardWindowButton(b)?.isHidden = true  // закрывает свой крестик справа
            }
            panel = p
        }
        panel?.contentViewController = NSHostingController(rootView: ExtensionHelperView(browser: browser))
        if let screen = NSScreen.main?.visibleFrame {
            panel?.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 24, y: screen.minY + 24))
        }
        panel?.orderFrontRegardless()
    }

    static func close() {
        panel?.close()
        panel = nil
    }
}

private struct ExtensionHelperView: View {
    let browser: Browser
    @ObservedObject private var setup = Setup.shared
    @State private var dragging = false

    private var installed: Bool {
        setup.browsers.first(where: { $0.browser == browser })?.extensionInstalled == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(installed ? "Готово" : "Установка в \(browser.nameIn)").font(.headline)
                Spacer()
                IconButton("xmark", "Закрыть подсказку", action: ExtensionHelper.close)
            }
            if installed {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.white, Color.brand)
                    Text("Расширение установлено").font(.title3.weight(.semibold))
                    Text("Кнопка «Скачать» появится под видео на YouTube, VK и других сайтах.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                step(1, "Включите «Режим разработчика» — переключатель справа вверху страницы.")
                step(2, "Перетащите эту папку на страницу расширений:")
                folder
                step(3, "Chrome спросит «Открыть DownMax?» — отметьте «Всегда разрешать» и нажмите «Открыть».")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .frame(width: 320, height: 430, alignment: .top)
        .background(Color.surface)
        .onChange(of: installed) { _, done in
            guard done else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { ExtensionHelper.close() }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.brand))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Папку можно схватить мышью: отдаётся как файл, Chrome принимает её в режиме разработчика.
    private var folder: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: BrowserExtension.folder.path))
                .resizable()
                .frame(width: 64, height: 64)
            Text("DownMax").font(.callout.weight(.medium))
            Text("перетащите в Chrome").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Color.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius)
            .strokeBorder(Color.brand.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        .onDrag { NSItemProvider(object: BrowserExtension.folder as NSURL) }
        .help("Перетащите папку на страницу расширений Chrome")
    }
}
