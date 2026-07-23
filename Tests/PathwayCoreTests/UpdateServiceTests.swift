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
///
/// Подготовку и запуск скрипта считает по отдельности: только раздельные
/// счётчики позволяют утверждать, что после `download()` скрипт ещё не
/// стартовал, а не просто «установка чем-то занималась».
final class FakeInstaller: UpdateInstalling, @unchecked Sendable {
    private(set) var prepared: URL?
    private(set) var prepareCount = 0
    private(set) var launchedBundle: URL?
    private(set) var launchCount = 0
    var error: (any Error)?
    var launchError: (any Error)?

    /// Путь, который `prepare` выдаёт за проверенный бандл. Настоящий установщик
    /// вернул бы распакованный .app, тесту достаточно любого стабильного URL.
    let preparedBundle = URL(fileURLWithPath: "/tmp/PathwayUpdateTest/Проводник.app")

    func prepare(archive: URL) throws -> URL {
        prepareCount += 1
        if let error { throw error }
        prepared = archive
        return preparedBundle
    }

    func launchInstaller(bundle: URL) throws {
        launchCount += 1
        if let launchError { throw launchError }
        launchedBundle = bundle
    }
}

/// Подменяет закрытие приложения: настоящее уронило бы прогон вместе с тестом.
final class FakeTerminator: AppTerminating, @unchecked Sendable {
    private(set) var terminateCount = 0

    func terminate() {
        terminateCount += 1
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
        terminator: FakeTerminator = FakeTerminator(),
        defaults: UserDefaults? = nil,
        session: URLSession = .shared
    ) -> UpdateService {
        UpdateService(
            currentVersion: AppVersion(current)!,
            fetcher: fetcher,
            installer: installer,
            terminator: terminator,
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

        #expect(service.state == .upToDate)
    }

    @Test("не предлагает откатиться на старую версию")
    @MainActor
    func ignoresOlderRelease() async {
        let service = makeService(fetcher: FakeReleaseFetcher(release: makeRelease("0.9.0")))

        await service.checkManually()

        #expect(service.state == .upToDate)
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

        #expect(service.state == .upToDate)
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

        #expect(service.state == .readyToRestart(makeRelease("1.1.0", size: 200_000), installer.preparedBundle))
        #expect(installer.prepared != nil)
    }

    @Test("нулевой ожидаемый размер не даёт NaN в прогрессе")
    @MainActor
    func zeroExpectedSizeDoesNotProduceNaN() async {
        // Ни Content-Length от сервера, ни ReleaseInfo.size не гарантированы —
        // деление на 0 без защиты дало бы .downloading(.nan) и сломало бы
        // отрисовку прогресс-бара.
        StubURLProtocol.data = Data(repeating: 0x41, count: 1024)
        StubURLProtocol.headers = [:]
        let installer = FakeInstaller()
        let service = makeService(
            fetcher: FakeReleaseFetcher(release: makeRelease("1.1.0", size: 0)),
            installer: installer,
            session: StubURLProtocol.session()
        )
        await service.checkManually()

        await service.download()

        #expect(service.state == .readyToRestart(makeRelease("1.1.0", size: 0), installer.preparedBundle))
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

        #expect(service.state == .readyToRestart(makeRelease("1.1.0", size: 4096), installer.preparedBundle))
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

    @Test("после загрузки скрипт подмены ещё не запущен, а после перезапуска запущен")
    @MainActor
    func downloadPreparesWithoutLaunchingHelper() async {
        // Ловит исходный дефект: install() последним действием стартовал скрипт,
        // то есть отсчёт «жду закрытия приложения» начинался сразу после
        // загрузки. Скрипт ждёт 10 секунд и выходит, а человек к кнопке
        // «Перезапустить» за это время почти никогда не успевает — обновление не
        // ставилось вовсе, молча и без обратной связи. Подготовка обязана
        // случиться при download(), запуск — только при restart().
        StubURLProtocol.data = Data(repeating: 0x41, count: 4096)
        StubURLProtocol.headers = ["Content-Length": "4096"]
        let installer = FakeInstaller()
        let terminator = FakeTerminator()
        let service = makeService(
            fetcher: FakeReleaseFetcher(release: makeRelease("1.1.0", size: 4096)),
            installer: installer,
            terminator: terminator,
            session: StubURLProtocol.session()
        )
        await service.checkManually()

        await service.download()

        #expect(installer.prepareCount == 1)
        // Ключевая проверка дефекта: скрипт не должен быть запущен, пока человек
        // не нажал «Перезапустить».
        #expect(installer.launchCount == 0)
        #expect(terminator.terminateCount == 0)
        #expect(service.state == .readyToRestart(makeRelease("1.1.0", size: 4096), installer.preparedBundle))

        service.restart()

        #expect(installer.launchCount == 1)
        // Запускается ровно тот бандл, который подготовили: путь берётся из
        // самого состояния, а не из отдельного поля рядом с ним.
        #expect(installer.launchedBundle == installer.preparedBundle)
        #expect(terminator.terminateCount == 1)
    }

    @Test("несостоявшийся запуск скрипта показывает ошибку, а не тихо закрывает приложение")
    @MainActor
    func failedHelperLaunchReportsErrorAndKeepsAppAlive() async {
        // Если скрипт не стартовал, подменять бандл после закрытия некому.
        // Закрыться молча — значит оставить человека без обновления и без
        // объяснения, поэтому restart() обязан остаться в .failed.
        StubURLProtocol.data = Data(repeating: 0x41, count: 4096)
        StubURLProtocol.headers = ["Content-Length": "4096"]
        let installer = FakeInstaller()
        installer.launchError = UpdateError.installFailed("тест")
        let terminator = FakeTerminator()
        let service = makeService(
            fetcher: FakeReleaseFetcher(release: makeRelease("1.1.0", size: 4096)),
            installer: installer,
            terminator: terminator,
            session: StubURLProtocol.session()
        )
        await service.checkManually()
        await service.download()

        service.restart()

        // Приложение обязано остаться живым: подменять бандл после закрытия
        // было бы некому.
        #expect(terminator.terminateCount == 0)

        guard case .failed(let message, let release) = service.state else {
            Issue.record("ожидалось состояние .failed после сбоя запуска, получено \(service.state)")
            return
        }
        #expect(message == UpdateError.installFailed("тест").localizedDescription)
        // Архив уже скачан и распакован: повторять имеет смысл проверку, а не
        // загрузку, поэтому релиза для повтора в состоянии нет.
        #expect(release == nil)
    }

    @Test("перезапуск без подготовленного обновления ничего не запускает")
    @MainActor
    func restartWithoutPreparedUpdateDoesNothing() async {
        // Состояние — единственный источник правды о готовности: нет
        // .readyToRestart, значит подменять нечем, и звать скрипт не с чем.
        let installer = FakeInstaller()
        let terminator = FakeTerminator()
        let service = makeService(
            fetcher: FakeReleaseFetcher(release: makeRelease("1.1.0")),
            installer: installer,
            terminator: terminator
        )

        service.restart()

        #expect(installer.launchCount == 0)
        #expect(terminator.terminateCount == 0)
    }

    @Test("подготовленный бандл пропал между download() и restart() — ошибка вместо запуска скрипта")
    @MainActor
    func restartWithMissingPreparedBundleFailsWithoutLaunchingScript() async {
        // Между «Скачано» и нажатием «Перезапустить» могут пройти часы: человек
        // отложил перезапуск, ушёл на выходные, а macOS тем временем почистила
        // TMPDIR. FakeInstaller.launchError воспроизводит именно то, что в этом
        // случае обязан вернуть настоящий BundleUpdateInstaller.launchInstaller —
        // preparedBundleMissing вместо попытки стартовать скрипт на путь, которого
        // больше нет. Проверка самой файловой проверки (существование и что это
        // бандл, а не мусор) — забота BundleUpdateInstaller и его собственного
        // кода; здесь важно, что restart() не путает эту ошибку с прочими и не
        // тащит за собой release для повтора загрузки архива, который тоже мог
        // исчезнуть вместе с распакованным бандлом.
        StubURLProtocol.data = Data(repeating: 0x41, count: 4096)
        StubURLProtocol.headers = ["Content-Length": "4096"]
        let installer = FakeInstaller()
        installer.launchError = UpdateError.preparedBundleMissing
        let terminator = FakeTerminator()
        let service = makeService(
            fetcher: FakeReleaseFetcher(release: makeRelease("1.1.0", size: 4096)),
            installer: installer,
            terminator: terminator,
            session: StubURLProtocol.session()
        )
        await service.checkManually()
        await service.download()

        service.restart()

        // Скрипт подмены пытался стартовать (launchInstaller вызван), но именно
        // счётчик реального запуска процесса — terminateCount — обязан остаться
        // нулевым: приложение не закрывается, пока некому подхватить подмену
        // после закрытия.
        #expect(installer.launchCount == 1)
        #expect(terminator.terminateCount == 0)

        guard case .failed(let message, let release) = service.state else {
            Issue.record("ожидалось состояние .failed после пропажи подготовленного бандла, получено \(service.state)")
            return
        }
        #expect(message == UpdateError.preparedBundleMissing.localizedDescription)
        #expect(release == nil)
    }

    @Test("настоящий установщик отказывается запускать скрипт, если подготовленный бандл исчез")
    func realInstallerRejectsMissingPreparedBundle() {
        // Это и есть проверка самого дефекта на уровне файловой системы: путь,
        // который якобы вело readyToRestart, ведёт в никуда — ровно то, что
        // происходит после того, как macOS почистила TMPDIR за часы простоя.
        // Без проверки в launchInstaller здесь бы стартовал скрипт: он
        // переименовал бы установленный бандл в .old, упал бы на ditto с
        // несуществующим источником и откатился — молча, без объяснения причины.
        let installer = BundleUpdateInstaller()
        let vanished = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathwayUpdateTest-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Проводник.app")

        #expect {
            try installer.launchInstaller(bundle: vanished)
        } throws: { error in
            (error as? UpdateError)?.errorDescription == UpdateError.preparedBundleMissing.errorDescription
        }
    }

    @Test("успешная проверка без нового релиза даёт upToDate, а не idle")
    @MainActor
    func successfulCheckWithoutNewReleaseIsUpToDate() async {
        // Поповер по этим двум случаям выбирает между «Установлена последняя
        // версия» и молчанием: сведи их снова в .idle — и приложение начнёт
        // утверждать, что версия последняя, ни разу не сходив на GitHub.
        let service = makeService(fetcher: FakeReleaseFetcher(release: makeRelease("1.0.0")))

        #expect(service.state == .idle)

        await service.checkManually()

        #expect(service.state == .upToDate)
    }

    @Test("дата последней проверки публикуется после успешного ответа")
    @MainActor
    func lastCheckIsPublishedAfterSuccess() async {
        let service = makeService(fetcher: FakeReleaseFetcher(release: makeRelease("1.1.0")))

        #expect(service.lastCheck == nil)

        let before = Date()
        await service.checkManually()

        guard let lastCheck = service.lastCheck else {
            Issue.record("дата последней проверки не заполнена после успешного ответа")
            return
        }
        #expect(lastCheck >= before)
    }

    @Test("неудачная проверка дату последней проверки не двигает")
    @MainActor
    func failedCheckDoesNotAdvanceLastCheck() async {
        // Подвал поповера пишет «Проверено в 21:59» из этого же значения. Запиши
        // сюда время неудачной попытки — и человек прочтёт, что проверка была,
        // хотя до GitHub достучаться не удалось.
        let fetcher = FakeReleaseFetcher(release: makeRelease("1.1.0"))
        let service = makeService(fetcher: fetcher)
        await service.checkManually()
        let afterSuccess = service.lastCheck

        fetcher.error = URLError(.notConnectedToInternet)
        await service.checkManually()

        #expect(service.lastCheck == afterSuccess)
    }

    @Test("дата последней проверки переживает перезапуск приложения")
    @MainActor
    func lastCheckSurvivesRelaunch() async {
        // Одно хранилище на два потребителя — ограничение суток и подпись в
        // поповере: заведи второе, и после перезапуска подпись разошлась бы с
        // тем, по чему считается интервал.
        let defaults = makeDefaults()
        let service = makeService(fetcher: FakeReleaseFetcher(release: makeRelease("1.1.0")), defaults: defaults)
        await service.checkManually()

        let relaunched = makeService(fetcher: FakeReleaseFetcher(), defaults: defaults)

        #expect(relaunched.lastCheck == service.lastCheck)
    }

    @Test("версия релиза доживает до готовности к перезапуску, а не теряется на загрузке")
    @MainActor
    func releaseVersionSurvivesUntilReadyToRestart() async {
        // Поповер на загрузке пишет «Загрузка версии 1.1.0…», а на готовности —
        // «Версия 1.1.0 готова к установке». Пока релиз лежал только в
        // .available, к этому моменту он был уже затёрт, и номер версии брать
        // было неоткуда.
        StubURLProtocol.data = Data(repeating: 0x41, count: 4096)
        StubURLProtocol.headers = ["Content-Length": "4096"]
        let service = makeService(
            fetcher: FakeReleaseFetcher(release: makeRelease("1.1.0", size: 4096)),
            session: StubURLProtocol.session()
        )
        await service.checkManually()

        await service.download()

        guard case .readyToRestart(let release, _) = service.state else {
            Issue.record("ожидалось состояние .readyToRestart, получено \(service.state)")
            return
        }
        #expect(release.version == AppVersion("1.1.0")!)
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
