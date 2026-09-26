import AppKit

// MARK: - Значок в строке меню

/// DownMax живёт в строке меню: окно можно закрыть — загрузки и приём ссылок с iPhone продолжаются,
/// а значок пропадает из Дока (см. AppDelegate). Значок показывает ход загрузок кольцом вокруг стрелки
/// и число загрузок; по щелчку — меню со списком идущих загрузок.
final class MenuBar: NSObject, NSMenuDelegate {
    static let shared = MenuBar()
    private var item: NSStatusItem?
    private var doneTimer: Timer?
    private var wasBusy = false

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = "DownMax"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        showIdle()
    }

    /// Вызывается из DockProgress каждые полсекунды, пока идут загрузки.
    func update(progress: Double, count: Int) {
        doneTimer?.invalidate()
        wasBusy = true
        item?.button?.image = Self.icon(progress: progress)
        item?.button?.title = count > 1 ? " \(count)" : ""
        item?.button?.toolTip = count == 1 ? "DownMax — идёт загрузка, \(Int(progress * 100))%"
                                           : "DownMax — идут загрузки: \(count)"
    }

    /// Загрузки закончились: пару секунд галочка, потом обычный значок.
    func finished() {
        guard wasBusy else { return showIdle() }
        wasBusy = false
        item?.button?.image = Self.symbol("checkmark.circle")
        item?.button?.title = ""
        item?.button?.toolTip = "DownMax — всё скачано"
        doneTimer?.invalidate()
        doneTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.showIdle() }
    }

    private func showIdle() {
        item?.button?.image = Self.symbol("arrow.down.circle")
        item?.button?.title = ""
        item?.button?.toolTip = "DownMax"
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "DownMax")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        image?.isTemplate = true
        return image
    }

    /// Стрелка вниз и кольцо прогресса: бледная дорожка и розовая дуга по часовой стрелке от 12 часов.
    /// Стрелка и дорожка — цветом текста строки меню (картинка перерисовывается под её оформление).
    private static func icon(progress: Double) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2 - 1.2
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 1.6
            NSColor.labelColor.withAlphaComponent(0.3).setStroke()
            track.stroke()

            let share = min(max(progress, 0.03), 1)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * share, clockwise: true)
            arc.lineWidth = 2.2
            arc.lineCapStyle = .round
            // на светлой строке меню 500 даёт меньше 3:1 — там ступень 600
            (NSAppearance.currentDrawing().isDark ? NSColor.brand : NSColor.brand600).setStroke()
            arc.stroke()

            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: center.x, y: center.y + 4.2))
            arrow.line(to: NSPoint(x: center.x, y: center.y - 3.6))
            arrow.move(to: NSPoint(x: center.x - 3.2, y: center.y - 0.6))
            arrow.line(to: NSPoint(x: center.x, y: center.y - 3.8))
            arrow.line(to: NSPoint(x: center.x + 3.2, y: center.y - 0.6))
            arrow.lineWidth = 1.7
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            NSColor.labelColor.setStroke()
            arrow.stroke()
            return true
        }
        image.isTemplate = false  // иначе macOS перекрасит розовую дугу в цвет строки меню
        return image
    }

    // MARK: Меню — собирается заново при каждом открытии

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let jobs = DownloadManager.shared.jobs.filter { $0.isRunning || $0.state == .paused }
        let torrents = TorrentManager.shared.torrents.filter { [.downloading, .paused, .seeding].contains($0.state) }
        if jobs.isEmpty && torrents.isEmpty {
            menu.addItem(disabled("Нет активных загрузок"))
        }
        for job in jobs.prefix(8) { menu.addItem(downloadItem(job.title, job.detail)) }
        for t in torrents.prefix(8) { menu.addItem(downloadItem(t.name, t.detail)) }
        if jobs.count + torrents.count > 16 { menu.addItem(disabled("…и ещё \(jobs.count + torrents.count - 16)")) }

        menu.addItem(.separator())
        menu.addItem(action("Открыть DownMax", #selector(openWindow)))
        let paste = action("Скачать ссылку из буфера обмена", #selector(downloadClipboard))
        paste.isEnabled = clipboardLink() != nil
        menu.addItem(paste)
        menu.addItem(.separator())
        menu.addItem(action("Проверить обновления…", #selector(checkUpdates)))
        menu.addItem(action("Оценить DownMax…", #selector(rate)))
        menu.addItem(action("Поддержать DownMax ♥", #selector(donate)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Завершить DownMax", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// Две строки: название загрузки и её ход («12 МБ из 80 МБ · 2 МБ/с…»); щелчок открывает окно.
    private func downloadItem(_ title: String, _ detail: String) -> NSMenuItem {
        let item = action(title, #selector(openWindow))
        let text = NSMutableAttributedString(string: title.count > 60 ? String(title.prefix(60)) + "…" : title,
                                             attributes: [.font: NSFont.menuFont(ofSize: 0)])
        text.append(NSAttributedString(string: "\n" + detail, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        item.attributedTitle = text
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func clipboardLink() -> String? {
        NSPasteboard.general.string(forType: .string).flatMap(LinkRouter.firstLink(in:))
    }

    @objc private func openWindow() {
        (NSApp.delegate as? AppDelegate)?.showMainWindow()
    }

    @objc private func downloadClipboard() {
        guard let link = clipboardLink() else { return }
        Task { @MainActor in _ = await LinkRouter.submit(link, origin: "clipboard") }
    }

    @objc private func donate() { Donate.showWindow(from: "menubar") }

    @objc private func rate() { Feedback.showWindow() }

    @objc private func checkUpdates() {
        NSApp.activate()
        Updater.shared.check(manual: true)
    }
}
