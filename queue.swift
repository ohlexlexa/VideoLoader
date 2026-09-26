import Foundation

// MARK: - Очередь загрузок

/// Сколько загрузок качается одновременно (меню «3 ▾» на панели над списком). Лимит общий для видео,
/// торрентов и файлов; раздачи и перекодирование в него не входят — они не занимают сеть так, как загрузка.
/// Лишние ждут в состоянии «В очереди» и запускаются по порядку добавления, когда освобождается место.
/// Ручные «Продолжить» и «Начать сейчас» лимит не спрашивают: пользователь сам решил.
enum DownloadQueue {
    static let key = "maxConcurrent"
    static let options = [1, 2, 3, 5, 0]  // 0 — без ограничений
    static let standard = 3

    static var limit: Int { UserDefaults.standard.object(forKey: key) as? Int ?? standard }

    /// Просто число (решение пользователя; раньше «По одной», «По 3»); что оно значит — заголовок меню
    /// «Качать одновременно» и подсказка.
    static func title(_ n: Int) -> String { n == 0 ? "∞" : String(n) }

    static var active: Int {
        DownloadManager.shared.jobs.filter { [.starting, .downloading].contains($0.state) && !$0.isConverting }.count
            + TorrentManager.shared.torrents.filter { $0.state == .downloading }.count
    }

    static var hasSlot: Bool { limit == 0 || active < limit }

    /// Лимит уменьшили: лишние идущие загрузки — обратно в очередь. Остаются те, что начались раньше.
    static func enforce() {
        guard limit > 0 else { return tick() }
        var running: [(added: Date, requeue: () -> Void)] =
            DownloadManager.shared.jobs.filter { [.starting, .downloading].contains($0.state) && !$0.isConverting }
                .map { job in (job.added ?? .distantPast, { job.requeue() }) }
        running += TorrentManager.shared.torrents.filter { $0.state == .downloading }
            .map { t in (t.record.added ?? .distantPast, { t.requeue() }) }
        for extra in running.sorted(by: { $0.added < $1.added }).dropFirst(limit) { extra.requeue() }
        tick()
    }

    private static var scheduled = false

    /// Что-то закончилось, встало на паузу или сменился лимит — запустить ждущие, пока есть место.
    /// Откладывается на следующий проход цикла: состояние меняется внутри обработчиков, пусть сначала всё обновится.
    static func tick() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async {
            scheduled = false
            if DownloadManager.shared.quitting || TorrentManager.shared.quitting { return }
            while hasSlot, startNext() {}
        }
    }

    private static func startNext() -> Bool {
        let video = DownloadManager.shared.jobs.filter { $0.state == .queued }
            .min { ($0.added ?? .distantPast) < ($1.added ?? .distantPast) }
        let torrent = TorrentManager.shared.torrents.filter { $0.state == .queued }
            .min { ($0.record.added ?? .distantPast) < ($1.record.added ?? .distantPast) }
        switch (video, torrent) {
        case let (v?, t?):
            if (v.added ?? .distantPast) <= (t.record.added ?? .distantPast) { v.resume() } else { t.start() }
        case let (v?, nil): v.resume()
        case let (nil, t?): t.start()
        default: return false
        }
        return true
    }
}
