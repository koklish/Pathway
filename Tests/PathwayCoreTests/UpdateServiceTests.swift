import Foundation
import Testing

@testable import PathwayCore

/// Подменяет GitHub: отдаёт заданный релиз и считает обращения.
final class FakeReleaseFetcher: ReleaseFetching, @unchecked Sendable {
    var release: ReleaseInfo?
    var error: (any Error)?
    private(set) var callCount = 0
    /// Ворота, которые держат `latestRelease()` в подвешенном состоянии, пока
    /// тест не откроет их сам — нужны, чтобы застать сервис ровно в `.checking`
    /// и оттуда позвать вторую проверку, не дожидаясь ответа первой.
    let gate: AsyncGate?

    init(release: ReleaseInfo? = nil, error: (any Error)? = nil, gate: AsyncGate? = nil) {
        self.release = release
        self.error = error
        self.gate = gate
    }

    func latestRelease() async throws -> ReleaseInfo? {
        callCount += 1
        if let gate { await gate.wait() }
        if let error { throw error }
        return release
    }
}

/// Простые ворота на continuation: `wait()` подвисает, пока кто-то не позовёт
/// `open()`. Замена `Task.sleep` там, где важна гарантия «застали именно этот
/// момент», а не «подождали и понадеялись, что успели».
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Подменяет установщик: настоящий трогает /Applications.
final class FakeInstaller: UpdateInstalling, @unchecked Sendable {
    private(set) var installed: URL?
    var error: (any Error)?

    func install(archive: URL) throws {
        if let error { throw error }
        installed = archive
    }
}

private func makeRelease(_ version: String, size: Int64 = 1024) -> ReleaseInfo {
    ReleaseInfo(
        version: AppVersion(version)!,
        archiveURL: URL(string: "https://example.com/Проводник.zip")!,
        notes: "Что нового",
        size: size
    )
}

/// Подменяет сетевой ответ на `session.bytes(from:)`: реального сервера для
/// загрузки архива в тестах нет, а `URLProtocol` — штатный способ Foundation
/// подставить ответ прямо в `URLSession`, не трогая сеть и не поднимая сервер.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    // nonisolated(unsafe): URLProtocol — фреймворковый класс с синхронными
    // static-требованиями от Foundation, актор тут не оформить, а стенд
    // работает строго последовательно — один тест настраивает и тут же
    // выполняет один запрос.
    nonisolated(unsafe) static var data = Data()
    nonisolated(unsafe) static var headers: [String: String] = [:]

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: Self.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Сервис обновлений")
struct UpdateServiceTests {
    /// Свежий suiteName на каждый тест: иначе дата последней проверки протекала бы
    /// между тестами и ограничение суток срабатывало бы непредсказуемо.
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "update-tests-\(UUID().uuidString)")!
    }

    @MainActor
    private func makeService(
        current: String = "1.0.0",
        fetcher: FakeReleaseFetcher,
        installer: FakeInstaller = FakeInstaller(),
        defaults: UserDefaults? = nil,
        session: URLSession = .shared
    ) -> UpdateService {
        UpdateService(
            currentVersion: AppVersion(current)!,
            fetcher: fetcher,
            installer: installer,
            defaults: defaults ?? makeDefaults(),
            session: session
        )
    }

    @Test("замечает релиз новее установленного")
    @MainActor
    func findsNewerRelease() async {
        let fetcher = FakeReleaseFetcher(release: makeRelease("1.1.0"))
        let service = makeService(fetcher: fetcher)

        await service.checkManually()

        #expect(service.state == .available(makeRelease("1.1.0")))
    }

    @Test("не предлагает обновиться на ту же версию")
    @MainActor
    func ignoresSameVersion() async {
        let service = makeService(fetcher: FakeReleaseFetcher(release: makeRelease("1.0.0")))

        await service.checkManually()

        #expect(service.state == .idle)
    }

    @Test("не предлагает откатиться на старую версию")
    @MainActor
    func ignoresOlderRelease() async {
        let service = makeService(fetcher: FakeReleaseFetcher(release: makeRelease("0.9.0")))

        await service.checkManually()

        #expect(service.state == .idle)
    }

    @Test("молчит, когда автопроверка не удалась")
    @MainActor
    func automaticFailureIsSilent() async {
        // Приложение в дороге без интернета не должно ругаться при каждом запуске.
        let fetcher = FakeReleaseFetcher(error: URLError(.notConnectedToInternet))
        let service = makeService(fetcher: fetcher)

        await service.checkAutomatically()

        #expect(service.state == .idle)
    }

    @Test("показывает ошибку, когда проверку запросил пользователь")
    @MainActor
    func manualFailureIsVisible() async {
        let fetcher = FakeReleaseFetcher(error: URLError(.notConnectedToInternet))
        let service = makeService(fetcher: fetcher)

        await service.checkManually()

        guard case .failed(_, let release) = service.state else {
            Issue.record("ожидалось состояние .failed, получено \(service.state)")
            return
        }
        // Упала проверка, а не загрузка — релиза для повтора нет и быть не может.
        #expect(release == nil)
    }

    @Test("повторный вызов проверки во время уже идущей не стартует второй запрос")
    @MainActor
    func checkDoesNotReenterWhileChecking() async {
        // Двойной клик по «Проверить обновления» не должен запускать параллельный
        // запрос к GitHub — иначе оба ответа гоняются за финальным state в гонке.
        let gate = AsyncGate()
        let fetcher = FakeReleaseFetcher(release: makeRelease("1.1.0"), gate: gate)
        let service = makeService(fetcher: fetcher)

        let first = Task { await service.checkManually() }
        while service.state != .checking {
            await Task.yield()
        }

        // Второй вызов не должен трогать gate вовсе — он обязан немедленно
        // вернуться сам благодаря гварду на .checking. Если бы гварда не было,
        // второй вызов точно так же упёрся бы в latestRelease() и завис на том
        // же gate, что и первый, а строка ниже никогда бы не выполнилась.
        await service.checkManually()

        // callCount тут может быть ещё 0: первый вызов уже в .checking, но сам
        // latestRelease() мог не успеть стартовать до своей первой точки
        // приостановки. Важно, что он не может быть 2 — это и значило бы, что
        // второй вызов пробился в сеть параллельно с первым.
        #expect(fetcher.callCount <= 1)

        await gate.open()
        await first.value
        #expect(fetcher.callCount == 1)
        #expect(service.state == .available(makeRelease("1.1.0")))
    }

    @Test("вторая автопроверка за сутки не идёт в сеть")
    @MainActor
    func automaticCheckIsThrottled() async {
        let fetcher = FakeReleaseFetcher(release: makeRelease("1.1.0"))
        let defaults = makeDefaults()
        let service = makeService(fetcher: fetcher, defaults: defaults)

        await service.checkAutomatically()
        await service.checkAutomatically()

        #expect(fetcher.callCount == 1)
    }

    @Test("ручная проверка ограничение суток не соблюдает")
    @MainActor
    func manualCheckIgnoresThrottle() async {
        let fetcher = FakeReleaseFetcher(release: makeRelease("1.1.0"))
        let defaults = makeDefaults()
        let service = makeService(fetcher: fetcher, defaults: defaults)

        await service.checkAutomatically()
        await service.checkManually()

        #expect(fetcher.callCount == 2)
    }

    @Test("неудачная автопроверка не засчитывается, следующая всё равно идёт в сеть")
    @MainActor
    func failedAutomaticCheckDoesNotThrottleNextOne() async {
        // Дата последней проверки не должна писаться до успешного ответа: иначе
        // однажды не достучавшись до сети, приложение замолкало бы на сутки,
        // хотя ни разу не проверило обновления по-настоящему.
        let fetcher = FakeReleaseFetcher(error: URLError(.notConnectedToInternet))
        let defaults = makeDefaults()
        let service = makeService(fetcher: fetcher, defaults: defaults)

        await service.checkAutomatically()
        await service.checkAutomatically()

        #expect(fetcher.callCount == 2)
    }

    @Test("отсутствие релизов не считается ошибкой")
    @MainActor
    func noReleasesIsNotAnError() async {
        let service = makeService(fetcher: FakeReleaseFetcher(release: nil))

        await service.checkManually()

        #expect(service.state == .idle)
    }

    @Test("скачивает архив и переводит в readyToRestart")
    @MainActor
    func downloadInstallsAndFinishes() async {
        StubURLProtocol.data = Data(repeating: 0x41, count: 200_000)
        StubURLProtocol.headers = ["Content-Length": "200000"]
        let installer = FakeInstaller()
        let service = makeService(
            fetcher: FakeReleaseFetcher(release: makeRelease("1.1.0", size: 200_000)),
            installer: installer,
            session: StubURLProtocol.session()
        )
        await service.checkManually()

        await service.download()

        #expect(service.state == .readyToRestart)
        #expect(installer.installed != nil)
    }

    @Test("нулевой ожидаемый размер не даёт NaN в прогрессе")
    @MainActor
    func zeroExpectedSizeDoesNotProduceNaN() async {
        // Ни Content-Length от сервера, ни ReleaseInfo.size не гарантированы —
        // деление на 0 без защиты дало бы .downloading(.nan) и сломало бы
        // отрисовку прогресс-бара.
        StubURLProtocol.data = Data(repeating: 0x41, count: 1024)
        StubURLProtocol.headers = [:]
        let service = makeService(
            fetcher: FakeReleaseFetcher(release: makeRelease("1.1.0", size: 0)),
            session: StubURLProtocol.session()
        )
        await service.checkManually()

        await service.download()

        #expect(service.state == .readyToRestart)
    }

    @Test("повторная загрузка после сбоя не требует новой проверки GitHub")
    @MainActor
    func downloadRetriesAfterFailureWithoutNewCheck() async {
        // После неудачной установки пользователь жмёт «Повторить» — это должно
        // сработать прямо из .failed, без повторного похода за релизом на GitHub.
        StubURLProtocol.data = Data(repeating: 0x41, count: 4096)
        StubURLProtocol.headers = ["Content-Length": "4096"]
        let installer = FakeInstaller()
        installer.error = UpdateError.installFailed("тест")
        let fetcher = FakeReleaseFetcher(release: makeRelease("1.1.0", size: 4096))
        let service = makeService(
            fetcher: fetcher,
            installer: installer,
            session: StubURLProtocol.session()
        )
        await service.checkManually()

        await service.download()
        guard case .failed(_, let release) = service.state else {
            Issue.record("ожидалось состояние .failed после сбоя установки, получено \(service.state)")
            return
        }
        #expect(release == makeRelease("1.1.0", size: 4096))

        installer.error = nil
        await service.download()

        #expect(service.state == .readyToRestart)
        #expect(fetcher.callCount == 1)
    }

    @Test("после сбоя загрузки и сбоя повторной проверки повтор загрузки не ставит устаревший релиз")
    @MainActor
    func downloadAfterFailedRecheckDoesNotInstallStaleRelease() async {
        // Воспроизводит дефект раздвоенного состояния: загрузка 1.1.0 падает,
        // затем пользователь жмёт «проверить» и эта проверка тоже падает
        // (сеть всё ещё недоступна) — на GitHub к этому моменту уже вышла 1.2.0.
        // Со старой схемой (отдельное поле lastAttemptedRelease) неудачная
        // проверка поле не трогала, и повторная загрузка молча ставила бы
        // закэшированную 1.1.0 вместо похода за актуальным релизом. С релизом
        // внутри .failed второй провал проверки обязан стереть 1.1.0 из
        // состояния — иначе один источник правды перестаёт быть одним.
        StubURLProtocol.data = Data(repeating: 0x41, count: 4096)
        StubURLProtocol.headers = ["Content-Length": "4096"]
        let installer = FakeInstaller()
        installer.error = UpdateError.installFailed("тест")
        let fetcher = FakeReleaseFetcher(release: makeRelease("1.1.0", size: 4096))
        let service = makeService(
            fetcher: fetcher,
            installer: installer,
            session: StubURLProtocol.session()
        )
        await service.checkManually()

        await service.download()
        guard case .failed(_, let releaseAfterDownloadFailure) = service.state else {
            Issue.record("ожидалось состояние .failed после сбоя установки, получено \(service.state)")
            return
        }
        #expect(releaseAfterDownloadFailure == makeRelease("1.1.0", size: 4096))

        // Повторная проверка тоже проваливается — сети всё ещё нет.
        fetcher.error = URLError(.notConnectedToInternet)
        await service.checkManually()
        guard case .failed(_, let releaseAfterCheckFailure) = service.state else {
            Issue.record("ожидалось состояние .failed после сбоя повторной проверки, получено \(service.state)")
            return
        }
        // Ключевая проверка: неудачная проверка обязана стереть старый релиз
        // из состояния, а не оставить его висеть отдельно от текста ошибки.
        #expect(releaseAfterCheckFailure == nil)

        installer.error = nil
        await service.download()

        // Релиза для повтора нет — download() не имеет права угадывать его из
        // старого состояния и обязан молча отказаться, а не поставить 1.1.0,
        // которая к этому моменту уже могла устареть.
        guard case .failed(_, let releaseAfterNoOpDownload) = service.state else {
            Issue.record("download() без релиза в состоянии не должен ничего запускать, получено \(service.state)")
            return
        }
        #expect(releaseAfterNoOpDownload == nil)
        #expect(fetcher.callCount == 2)
    }

    @Test("разбирает ответ GitHub")
    func parsesGitHubPayload() throws {
        let json = """
        {
          "tag_name": "v1.5.0",
          "body": "Исправлены ошибки",
          "draft": false,
          "prerelease": false,
          "assets": [
            {"name": "Проводник.zip",
             "browser_download_url": "https://example.com/a.zip",
             "size": 2048}
          ]
        }
        """.data(using: .utf8)!

        let release = try GitHubReleaseFetcher.parse(json)

        #expect(release?.version == AppVersion("1.5.0")!)
        #expect(release?.size == 2048)
        #expect(release?.notes == "Исправлены ошибки")
    }

    @Test("пропускает предрелиз")
    func skipsPrerelease() throws {
        let json = """
        {
          "tag_name": "v2.0.0", "body": "", "draft": false, "prerelease": true,
          "assets": [{"name": "a.zip", "browser_download_url": "https://e.com/a.zip", "size": 1}]
        }
        """.data(using: .utf8)!

        #expect(try GitHubReleaseFetcher.parse(json) == nil)
    }

    @Test("пропускает релиз без архива")
    func skipsReleaseWithoutArchive() throws {
        // Обновляться нечем — ведём себя так, будто релиза нет.
        let json = """
        {"tag_name": "v2.0.0", "body": "", "draft": false, "prerelease": false, "assets": []}
        """.data(using: .utf8)!

        #expect(try GitHubReleaseFetcher.parse(json) == nil)
    }
}
