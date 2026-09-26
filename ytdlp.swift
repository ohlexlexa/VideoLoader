import SwiftUI

// MARK: - Автообновление yt-dlp

/// Сайты меняются часто, и старый yt-dlp перестаёт их понимать — это главная причина «не качает» у всех
/// программ на yt-dlp. Поэтому DownMax сам проверяет его версию: раз в сутки и сразу после ошибки
/// «сайт изменился» или 403. Обновляет, только когда ничего не качается.
enum YtdlpAutoUpdate {
    /// Переключатель в «Компонентах».
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "ytdlpAutoUpdate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ytdlpAutoUpdate") }
    }

    private static let lastCheckKey = "ytdlpLastCheck"
    private static let latestURL = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
    private static var checking = false
    private static var timer: Timer?
    /// Версия, которую уже пробовали поставить: у Homebrew новая версия появляется на несколько часов позже GitHub,
    /// и до тех пор `brew upgrade` ничего не меняет — не дёргать его на каждой проверке.
    private static var attempted: (version: String, at: Date)?

    static func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { _ in check(every: 24 * 3600) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { check(every: 24 * 3600) }
    }

    /// После ошибки, которую обычно лечит обновление: проверить сразу, но не чаще раза в час.
    static func afterFailure() {
        check(every: 3600)
    }

    private static func check(every interval: TimeInterval) {
        guard enabled, !checking else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > interval else { return }
        guard let ytdlp = Tools.find("yt-dlp") else { return }
        checking = true
        var request = URLRequest(url: latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let latest = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["tag_name"] as? String
            let current = Tools.firstLine(ytdlp, ["--version"])
            DispatchQueue.main.async {
                checking = false
                guard let latest, let current else { return }  // нет сети — попробуем в следующий раз
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
                guard isNewer(latest, than: current) else { return }
                if let a = attempted, a.version == latest, Date().timeIntervalSince(a.at) < 6 * 3600 { return }
                attempted = (latest, Date())
                update(ytdlp, to: latest)
            }
        }.resume()
    }

    /// Версии yt-dlp — даты: «2026.09.20», бывает «2026.09.20.1».
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").compactMap { Int($0) }, y = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : 0) != (i < y.count ? y[i] : 0) {
            return (i < x.count ? x[i] : 0) > (i < y.count ? y[i] : 0)
        }
        return false
    }

    private static func update(_ ytdlp: String, to version: String) {
        // Пока yt-dlp качает, его не трогаем — проверим снова через 3 часа (таймер) или после следующей ошибки.
        guard !DownloadManager.shared.jobs.contains(where: { $0.isRunning && $0.gallery == nil }) else {
            UserDefaults.standard.removeObject(forKey: lastCheckKey)
            attempted = nil
            return
        }
        let setup = Setup.shared
        guard setup.busy == nil else { return }
        // Тем же путём, что «Обновить сейчас»: Homebrew, свой (скачать заново) или сам yt-dlp (-U). Ход виден в «Компонентах».
        let real = (try? FileManager.default.destinationOfSymbolicLink(atPath: ytdlp)) ?? ytdlp
        if real.contains("/Cellar/yt-dlp/") && setup.brewPath == nil { return }
        Inbox.shared.note("yt-dlp: доступна \(version), обновляю")
        setup.updateYtdlp()
    }
}

/// Строка в «Компонентах»: переключатель автообновления.
struct YtdlpUpdateRow: View {
    @ObservedObject var setup: Setup
    @State private var on = YtdlpAutoUpdate.enabled

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(on ? .green : .secondary)
                .font(.title3)
                .frame(width: 22)  // одна колонка значков во всех карточках «Компонентов»
            VStack(alignment: .leading, spacing: 2) {
                Text("Обновлять yt-dlp автоматически").font(.headline)
                Text("Раз в день и сразу после ошибки загрузки")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Обновить сейчас", action: setup.updateYtdlp)
                .disabled(setup.busy != nil)
                .help("Если видео перестали скачиваться, обычно помогает обновление")
            Toggle("", isOn: $on)
                .toggleStyle(.switch)
                .tint(.brand)
                .labelsHidden()
                .onChange(of: on) { _, value in YtdlpAutoUpdate.enabled = value }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Color.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Color.hairline))
    }
}
