import AppKit

// MARK: - Перенос в «Программы»

/// Скачал, открыл — и DownMax сам переезжает в «Программы»: без .dmg и перетаскивания (решение пользователя).
/// Приложение, открытое из «Загрузок» с карантином, macOS запускает из случайной временной папки только для чтения
/// (App Translocation) — настоящий путь узнаём у Security. Переносим, снимаем карантин и перезапускаемся оттуда.
enum AppMover {
    private static let declinedKey = "moveDeclined"

    /// true — DownMax переезжает и сейчас перезапустится: дальше запускать ничего не надо.
    static func moveIfNeeded() -> Bool {
        let fm = FileManager.default
        let running = URL(fileURLWithPath: Bundle.main.bundlePath)
        let source = originalURL(of: running) ?? running
        let folder = source.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        guard folder != "/Applications", folder != home + "/Applications",
              !UserDefaults.standard.bool(forKey: declinedKey) else { return false }

        let target = URL(fileURLWithPath: "/Applications/" + source.lastPathComponent)
        let replacing = fm.fileExists(atPath: target.path)
        let answer = Ask.run("Перенести DownMax в «Программы»?",
                             "Сейчас он открыт из папки «\(fm.displayName(atPath: folder))». "
                             + "В «Программах» DownMax будет обновляться и открываться как обычное приложение."
                             + (replacing ? " Прежняя версия отправится в Корзину." : ""),
                             buttons: ["Перенести", "Оставить здесь"])
        guard answer == 0 else {
            UserDefaults.standard.set(true, forKey: declinedKey)
            return false
        }
        do {
            if replacing { try fm.trashItem(at: target, resultingItemURL: nil) }
            do {
                try fm.moveItem(at: source, to: target)
            } catch {
                // Из архива на другом диске или без права переноса — копия, исходник в Корзину
                try fm.copyItem(at: source, to: target)
                try? fm.trashItem(at: source, resultingItemURL: nil)
            }
        } catch {
            Ask.run("Не получилось перенести DownMax", error.localizedDescription + "\nПеретащите его в «Программы» вручную.")
            return false
        }
        // Разрешение на запуск уже дали — снимаем карантин, иначе macOS снова запустит из временной папки.
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", target.path])
        // Новый DownMax открываем, когда этот завершится: два сразу macOS не запустит.
        let pid = ProcessInfo.processInfo.processIdentifier
        run("/bin/sh", ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"$0\"", target.path], wait: false)
        exit(0)
    }

    /// Исходный путь приложения, если macOS запустила его из временной папки (App Translocation).
    private static func originalURL(of url: URL) -> URL? {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isSym = dlsym(handle, "SecTranslocateIsTranslocatedURL"),
              let origSym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias IsFn = @convention(c) (CFURL, UnsafeMutablePointer<DarwinBoolean>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean
        typealias OrigFn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let isTranslocated = unsafeBitCast(isSym, to: IsFn.self)
        let original = unsafeBitCast(origSym, to: OrigFn.self)
        var flag: DarwinBoolean = false
        guard isTranslocated(url as CFURL, &flag, nil).boolValue, flag.boolValue else { return nil }
        return original(url as CFURL, nil)?.takeRetainedValue() as URL?
    }

    private static func run(_ tool: String, _ args: [String], wait: Bool = true) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try? p.run()
        if wait { p.waitUntilExit() }
    }
}
