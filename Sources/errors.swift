import Foundation

// MARK: - Понятные ошибки

/// Переводит ошибки yt-dlp, aria2c и сети на человеческий: что случилось и что делать.
/// Исходный текст не теряется — его видно в подробностях загрузки и он уходит в отзыв.
enum Failure {
    /// Ошибка yt-dlp — строка после «ERROR: ». temporary — ссылка ведёт прямо на файл с CDN (Threads, карусель):
    /// такие ссылки живут несколько часов, и 403 у них значит «устарела».
    static func video(_ raw: String, temporary: Bool = false, ytdlpVersion: String? = nil) -> String {
        classify(raw, temporary: temporary, ytdlpVersion: ytdlpVersion).text
    }

    /// Вид ошибки одним словом — для статистики (сам текст ошибки не отправляется).
    static func kind(_ raw: String, temporary: Bool = false) -> String {
        classify(raw, temporary: temporary, ytdlpVersion: nil).kind
    }

    private static func classify(_ raw: String, temporary: Bool, ytdlpVersion: String?) -> (kind: String, text: String) {
        let s = raw.lowercased()
        func has(_ parts: String...) -> Bool { parts.contains { s.contains($0) } }

        if has("not a bot") {
            return ("robot", "YouTube принял загрузку за робота. Подождите несколько минут и нажмите ↻.")
        }
        if has("confirm your age", "age-restricted", "age restricted", "inappropriate for some users") {
            return ("age", "Видео 18+. YouTube отдаёт его только после входа в аккаунт.")
        }
        if has("members-only", "join this channel") {
            return ("members", "Видео только для спонсоров канала.")
        }
        if has("drm") {
            return ("drm", "Видео защищено от копирования (DRM), его не скачать.")
        }
        if has("rate-limit reached or login required", "empty media response") {
            return ("instagram_limit", "Instagram не отдал видео: пост закрыт или сайт ограничил загрузки. Подождите и нажмите ↻.")
        }
        if has("playlist does not exist", "this playlist is private") {
            return ("playlist_closed", "Плейлист закрыт или удалён. Если он ваш, откройте его на YouTube и поставьте доступ «По ссылке».")
        }
        if has("private video", "this video is private", "login required", "log in", "sign in", "login page",
               "requires authentication", "cookies") {
            return ("login", "Видео закрыто: его видно только после входа в аккаунт. DownMax качает открытые видео.")
        }
        if has("available in your country", "geo restrict", "georestrict", "not available from your location",
               "ip address is blocked") {  // так TikTok закрывает ролики для страны
            return ("region", "Видео недоступно в вашей стране.")
        }
        if has("will begin in", "premieres in", "live event will begin", "is upcoming") {
            return ("not_started", "Трансляция или премьера ещё не началась.")
        }
        if has("no video in this post", "does not contain a video", "no video could be found") {
            return ("no_video", "В посте нет видео, только фото или текст.")
        }
        if has("unsupported url") {
            return ("unsupported", "Этот сайт DownMax пока не умеет скачивать.")
        }
        if has("is not a valid url") {
            return ("bad_url", "Это не похоже на ссылку. Проверьте, что скопировали её целиком.")
        }
        if has("requested format is not available") {
            return ("format", "У видео нет такого качества. Выберите в меню другое «Качество видео» и нажмите ↻.")
        }
        if has("ffmpeg not found", "ffprobe not found", "ffmpeg is not installed") {
            return ("ffmpeg", "Не найден ffmpeg. Установите его в «Компонентах» внизу окна.")
        }
        if has("no space left", "errno 28") {
            return ("disk", "На диске не хватает места.")
        }
        if has("permission denied", "operation not permitted", "errno 13", "read-only file system") {
            return ("permission", "Нет доступа к папке загрузки. Выберите другую папку и нажмите ↻.")
        }
        if has("http error 429", "too many requests") {
            return ("rate_limit", "Сайт ограничил число загрузок. Подождите 10–15 минут и нажмите ↻.")
        }
        if has("http error 403", "forbidden") {
            return temporary
                ? ("link_expired", "Ссылка на файл устарела. Откройте пост заново и скачайте ещё раз.")
                : ("forbidden", "Сайт не отдал видео (ошибка 403). Нажмите ↻, а если не поможет, обновите yt-dlp в «Компонентах».")
        }
        if has("http error 404", "not found") && !has("ffmpeg", "ffprobe") {
            return temporary
                ? ("link_expired", "Ссылка на файл устарела. Откройте пост заново и скачайте ещё раз.")
                : ("not_found", "Видео удалено или ссылка с ошибкой.")
        }
        if has("unavailable", "has been removed", "no longer available", "does not exist", "been deleted") {
            return ("removed", "Видео удалено, скрыто автором или ссылка с ошибкой.")
        }
        if has("timed out", "connection reset", "connection refused", "connection aborted", "nodename nor servname",
               "network is unreachable", "name resolution", "failed to resolve", "remote end closed",
               "incompleteread", "ssl", "http error 5", "getaddrinfo", "urlopen error") {
            return ("network", "Нет связи с сайтом. Проверьте интернет и нажмите ↻.")
        }
        if has("unable to extract", "failed to parse json", "nsig", "signature", "no video formats found",
               "unable to download json", "keyerror", "report this issue", "confirm you are on the latest version") {
            return ("site_changed", siteChanged(ytdlpVersion))
        }
        let text = clean(raw)
        return ("other", text.isEmpty ? "Не получилось скачать. Нажмите ↻, чтобы попробовать ещё раз." : "Не получилось скачать: \(text)")
    }

    /// Нужна ли для этой ошибки версия yt-dlp (чтобы назвать её дату в подсказке).
    static func needsVersion(_ raw: String) -> Bool {
        kind(raw) == "site_changed"
    }

    private static func siteChanged(_ version: String?) -> String {
        // Версия yt-dlp — дата выпуска: «2026.08.19». Сайты меняются часто, исправления выходят за дни.
        if let version, let date = versionDate(version), Date().timeIntervalSince(date) > 30 * 86400 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ru_RU")
            f.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "d MMMM" : "d MMMM yyyy"
            return "Сайт изменился, а yt-dlp у вас от \(f.string(from: date)). Обновите его в «Компонентах»."
        }
        return "Сайт изменился, и yt-dlp его пока не понимает. Обновите yt-dlp в «Компонентах»."
    }

    private static func versionDate(_ version: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy.MM.dd"
        return f.date(from: String(version.prefix(10)))
    }

    /// Срезает из текста yt-dlp то, что человеку ничего не говорит: «[youtube] abc123: », просьбы прислать отчёт,
    /// ссылки на вики.
    static func clean(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "ERROR: ", with: "")
        s = s.replacingOccurrences(of: #"^\[[^\]]+\]\s*[^:\s]*:\s*"#, with: "", options: .regularExpression)
        for tail in ["; please report this issue", "please report this issue", "Confirm you are on the latest version",
                     "; see  https://", "; see https://", "See https://", "(caused by"] {
            if let r = s.range(of: tail, options: .caseInsensitive) { s = String(s[..<r.lowerBound]) }
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " .;,").union(.whitespacesAndNewlines))
    }

    /// Файл по прямой ссылке (карусель Instagram) сервер не отдал.
    static func http(_ code: Int, file: Int) -> String {
        switch code {
        case 403, 404, 410: "Ссылка на файл устарела. Откройте пост заново и скачайте ещё раз."
        case 429: "Сайт ограничил число загрузок. Подождите 10–15 минут и нажмите ↻."
        case 500...: "Сервер не отдал файл \(file): у него сбой. Попробуйте позже."
        default: "Сервер не отдал файл \(file) (ошибка \(code))."
        }
    }

    /// Ошибки URLSession и файловой системы: системный текст длинный и про «сервер с именем…».
    static func system(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "Нет интернета. Проверьте подключение и нажмите ↻."
            case .timedOut:
                return "Сайт не ответил вовремя. Нажмите ↻."
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
                return "Не удалось связаться с сайтом. Проверьте интернет и нажмите ↻."
            case .badURL, .unsupportedURL:
                return "Ссылка с ошибкой."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
                return "Не удалось установить защищённое соединение с сайтом."
            default: break
            }
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteOutOfSpaceError: return "На диске не хватает места."
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteVolumeReadOnlyError:
                return "Нет доступа к папке загрузки. Выберите другую папку и нажмите ↻."
            default: break
            }
        }
        return error.localizedDescription
    }

    /// Вид системной ошибки для статистики (карусели: сеть, диск, ответ сервера).
    static func systemKind(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "DownMax" { return [403, 404, 410].contains(ns.code) ? "link_expired" : "http_\(ns.code)" }
        if error is URLError { return "network" }
        if ns.domain == NSCocoaErrorDomain {
            if ns.code == NSFileWriteOutOfSpaceError { return "disk" }
            if [NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(ns.code) {
                return "permission"
            }
        }
        return "other"
    }

    /// Код выхода aria2c (торренты и файлы по прямым ссылкам). Коды — из документации aria2c, «EXIT STATUS».
    static func aria2(_ code: Int32, raw: String?) -> String {
        switch code {
        case 2: return "Сервер не ответил вовремя. Нажмите ↻."
        case 3: return "Файла по этой ссылке нет: его убрали или ссылка устарела."
        case 5: return "Загрузка шла слишком медленно, и aria2c её остановил. Нажмите ↻."
        case 6: return "Нет связи с сетью. Проверьте интернет и нажмите ↻."
        case 8: return "Сервер не умеет продолжать загрузку с места остановки. Нажмите ↻, чтобы начать заново."
        case 9: return "На диске не хватает места."
        case 13, 15, 16, 17, 18: return "Не получается записать файлы в папку загрузки."
        case 19: return "Не удалось найти сервер. Проверьте интернет и ссылку."
        case 22: return "Сервер ответил ошибкой. Попробуйте позже."
        case 24: return "Сервер пускает только после входа. Скачайте этот файл в браузере."
        case 26, 27: return "Торрент-файл повреждён или это не торрент."
        default:
            if let raw, !raw.isEmpty { return "Не получилось скачать: \(raw)" }
            return "aria2c остановился с ошибкой (код \(code)). Нажмите ↻, чтобы попробовать ещё раз."
        }
    }
}
