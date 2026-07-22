import Foundation

/// Вышедший релиз на GitHub.
public struct ReleaseInfo: Sendable, Equatable {
    public let version: AppVersion
    /// Прямая ссылка на ZIP с бандлом.
    public let archiveURL: URL
    /// Заметки к выпуску — показываются в поповере значка.
    public let notes: String
    public let size: Int64

    public init(version: AppVersion, archiveURL: URL, notes: String, size: Int64) {
        self.version = version
        self.archiveURL = archiveURL
        self.notes = notes
        self.size = size
    }
}

/// Где приложение узнаёт о новых версиях.
///
/// Протокол, а не прямой вызов сети: иначе тесты сервиса ходили бы на GitHub —
/// медленно, ненадёжно и с оглядкой на лимит запросов.
public protocol ReleaseFetching: Sendable {
    /// Последний релиз, либо nil, если релизов нет или к ним не приложен ZIP.
    func latestRelease() async throws -> ReleaseInfo?
}

/// Спрашивает GitHub о последнем релизе.
public struct GitHubReleaseFetcher: ReleaseFetching {
    private let endpoint: URL
    private let session: URLSession

    /// Репозиторий публичный, поэтому запрос идёт без авторизации: токен в
    /// раздаваемом коллегам бинарнике всё равно что опубликован.
    public init(
        repository: String = "koklish/Pathway",
        session: URLSession = .shared
    ) {
        endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        self.session = session
    }

    public func latestRelease() async throws -> ReleaseInfo? {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Без User-Agent GitHub отвечает 403 — требование их API, не наша прихоть.
        request.setValue("Pathway", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        // 404 — релизов ещё нет: это нормальное состояние свежего репозитория,
        // а не ошибка, о которой стоит говорить пользователю. Остальные не-200
        // (403 — лимит запросов, 5xx — сбой на стороне GitHub) — это уже
        // ошибка: молчаливое «релизов нет» превратило бы её в ложное
        // «обновлений нет» при ручной проверке.
        guard http.statusCode != 404 else { return nil }
        guard http.statusCode == 200 else { throw ReleaseCheckError(statusCode: http.statusCode) }

        return try Self.parse(data)
    }

    /// Разбирает ответ GitHub. Отделено от запроса, чтобы проверять без сети.
    static func parse(_ data: Data) throws -> ReleaseInfo? {
        struct Payload: Decodable {
            let tagName: String
            let body: String?
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]

            struct Asset: Decodable {
                let name: String
                let browserDownloadURL: URL
                let size: Int64

                enum CodingKeys: String, CodingKey {
                    case name
                    case browserDownloadURL = "browser_download_url"
                    case size
                }
            }

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case body
                case draft
                case prerelease
                case assets
            }
        }

        // Явные CodingKeys, а не .convertFromSnakeCase: стратегия конвертирует
        // browser_download_url в browserDownloadUrl (строчные "rl" — аббревиатуры
        // она не распознаёт), а свойство названо browserDownloadURL — ключи не
        // совпадали, decode падал с keyNotFound, и parse молча возвращал nil на
        // настоящем ответе GitHub. Явные ключи сверяются с документацией API
        // глазом и не ломаются от подобных несовпадений регистра.
        // Статус 200, но тело не разобралось — это не «релизов нет», а поломка
        // формата ответа (GitHub сменил схему?). decode бросает сам — ошибку
        // пробрасываем наверх, а не глотаем в nil, иначе такой сбой выглядел
        // бы для пользователя как «обновлений нет».
        let decoder = JSONDecoder()
        let payload = try decoder.decode(Payload.self, from: data)
        // Черновики и предрелизы коллегам не раздаём: их видно только владельцу
        // репозитория, и обновляться на них никто не просил.
        guard !payload.draft, !payload.prerelease else { return nil }
        guard let version = AppVersion(payload.tagName) else { return nil }
        // Релиз без приложенного ZIP обновить нечем — ведём себя как будто его нет.
        guard let asset = payload.assets.first(where: { $0.name.hasSuffix(".zip") }) else { return nil }

        return ReleaseInfo(
            version: version,
            archiveURL: asset.browserDownloadURL,
            notes: payload.body ?? "",
            size: asset.size
        )
    }
}

/// Не удалось спросить GitHub о релизах.
public struct ReleaseCheckError: LocalizedError {
    public let statusCode: Int

    public init(statusCode: Int) {
        self.statusCode = statusCode
    }

    public var errorDescription: String? {
        // 403 у GitHub означает превышенный лимит запросов: без авторизации
        // разрешено 60 обращений в час на адрес.
        statusCode == 403
            ? "GitHub временно ограничил число запросов. Попробуйте позже."
            : "GitHub ответил ошибкой \(statusCode)."
    }
}
