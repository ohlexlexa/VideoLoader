import SwiftUI

// MARK: - Компоненты без Homebrew

/// Где лежат программы, которые DownMax ставит сам. Не в Caches: ту папку приложение чистит при запуске.
/// aria2c собран нами (готового для Mac нет) и лежит в самом приложении — торренты работают сразу.
enum ToolFolder {
    static let bin = NSHomeDirectory() + "/Library/Application Support/DownMax/bin"
    static var bundled: String { Bundle.main.bundlePath + "/Contents/Helpers" }

    /// Программа поставлена DownMax, а не Homebrew или вручную.
    static func owns(_ path: String) -> Bool {
        path.hasPrefix(bin + "/") || path.hasPrefix(bundled + "/")
    }
}

/// Готовые программы для Mac: yt-dlp и deno — с их страниц релизов на GitHub, ffmpeg и ffprobe — сборки
/// Мартина Ридля (подписаны и заверены Apple, отдельно для Apple Silicon и Intel). Пароль не нужен:
/// всё кладётся в папку пользователя. Скачанное через URLSession не помечается карантином — macOS не спрашивает.
enum ComponentDownload {
    struct File {
        let name: String      // что появится в bin
        let urls: [URL]       // по порядку: второй — если первый не ответил
        let megabytes: Int    // для общей полосы: примерный размер
    }

    #if arch(arm64)
    static let arch = (deno: "aarch64", ffmpeg: "arm64")
    #else
    static let arch = (deno: "x86_64", ffmpeg: "amd64")
    #endif

    static func files(for id: String) -> [File] {
        switch id {
        case "yt-dlp":
            // Распакованная сборка (onedir): запускается за доли секунды. Одним файлом yt-dlp распаковывает себя
            // при каждом запуске — это секунда-две на каждое название и каждую загрузку.
            return [File(name: "yt-dlp", urls: [URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos.zip")!],
                         megabytes: 54)]
        case "ffmpeg":
            return ["ffmpeg", "ffprobe"].map { name in
                File(name: name, urls: ["release", "snapshot"].map {
                    URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(arch.ffmpeg)/\($0)/\(name).zip")!
                }, megabytes: 25)
            }
        case "deno":
            return [File(name: "deno", urls: [URL(string: "https://github.com/denoland/deno/releases/latest/download/deno-\(arch.deno)-apple-darwin.zip")!],
                         megabytes: 40)]
        default:
            return []
        }
    }

    /// Скачивает и раскладывает файлы по очереди. progress(доля от 0 до 1, подпись) — на главной очереди.
    /// placed(id) — программа уже на месте (для отметки «готово» в списке, пока качаются остальные).
    static func install(_ ids: [String], progress: @escaping (Double, String) -> Void,
                        placed: @escaping (String) -> Void = { _ in }) async throws {
        let items = ids.flatMap { id in files(for: id).map { (id: id, file: $0) } }
        let total = Double(items.map(\.file.megabytes).reduce(0, +))
        var done = 0.0
        try FileManager.default.createDirectory(atPath: ToolFolder.bin, withIntermediateDirectories: true)
        for (i, item) in items.enumerated() {
            let label = items.count > 1 ? "Скачиваю \(item.file.name) (\(i + 1) из \(items.count))" : "Скачиваю \(item.file.name)"
            let share = Double(item.file.megabytes) / total
            let base = done
            let zip = try await download(item.file.urls) { fraction in
                progress(base + share * fraction, label)
            }
            defer { try? FileManager.default.removeItem(at: zip) }
            await MainActor.run { progress(base + share, "Распаковываю \(item.file.name)") }
            try place(item.file.name, from: zip)
            await MainActor.run { placed(item.id) }
            done += share
        }
        await MainActor.run { progress(1, "Готово") }
    }

    /// Первый ответивший адрес. Ход — по байтам задачи (раз в 0,2 с), без делегата на каждый кусок.
    private static func download(_ urls: [URL], progress: @escaping (Double) -> Void) async throws -> URL {
        var lastError: Error = URLError(.badURL)
        for url in urls {
            let watcher = TaskWatcher()
            let timer = await MainActor.run {
                Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                    guard let t = watcher.task, t.countOfBytesExpectedToReceive > 0 else { return }
                    progress(min(1, Double(t.countOfBytesReceived) / Double(t.countOfBytesExpectedToReceive)))
                }
            }
            defer { DispatchQueue.main.async { timer.invalidate() } }  // таймер живёт на главной очереди
            do {
                let (file, response) = try await URLSession.shared.download(for: URLRequest(url: url, timeoutInterval: 60),
                                                                           delegate: watcher)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    try? FileManager.default.removeItem(at: file)
                    lastError = URLError(.fileDoesNotExist)
                    continue
                }
                // Временный файл URLSession удалит, как только вернём управление, — сразу уносим к себе.
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
                try FileManager.default.moveItem(at: file, to: kept)
                return kept
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private final class TaskWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        var task: URLSessionTask?
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) { self.task = task }
    }

    /// Распаковывает архив и ставит программу на место старой (обновление — тот же путь).
    private static func place(_ name: String, from zip: URL) throws {
        let fm = FileManager.default
        let staging = ToolFolder.bin + "/.unpack-" + name
        try? fm.removeItem(atPath: staging)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, staging]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        defer { try? fm.removeItem(atPath: staging) }

        let target = ToolFolder.bin + "/" + name
        if name == "yt-dlp" {
            // Папка со сборкой и ссылка bin/yt-dlp на её программу.
            let dir = ToolFolder.bin + "/yt-dlp.dist"
            guard fm.isExecutableFile(atPath: staging + "/yt-dlp_macos") else { throw CocoaError(.fileReadCorruptFile) }
            try? fm.removeItem(atPath: dir)
            try fm.moveItem(atPath: staging, toPath: dir)
            try? fm.removeItem(atPath: target)
            try fm.createSymbolicLink(atPath: target, withDestinationPath: dir + "/yt-dlp_macos")
        } else {
            // В архиве одна программа — ищем по имени, где бы она ни лежала.
            guard let found = fm.enumerator(atPath: staging)?.compactMap({ $0 as? String })
                .first(where: { ($0 as NSString).lastPathComponent == name }) else { throw CocoaError(.fileReadCorruptFile) }
            try? fm.removeItem(atPath: target)
            try fm.moveItem(atPath: staging + "/" + found, toPath: target)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
        }
    }
}
