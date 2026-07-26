import Foundation
import Testing

@testable import PathwayCore

/// Подменяет Центр уведомлений: настоящий в тестовом процессе недоступен —
/// приложение выполняется не из бандла, и `UNUserNotificationCenter.current()`
/// там бросает исключение.
///
/// Запросы разрешения и показанные релизы считает по отдельности: только
/// раздельные счётчики позволяют утверждать, что проверка обновлений разрешение
/// не спрашивает, а показ баннера не зависит от того, спрашивали ли его.
final class SpyNotifier: UpdateNotifying, @unchecked Sendable {
    private(set) var authorizationCount = 0
    private(set) var notifiedReleases: [ReleaseInfo] = []

    func requestAuthorization() async {
        authorizationCount += 1
    }

    func notify(about release: ReleaseInfo) async {
        notifiedReleases.append(release)
    }
}

@Suite("Уведомление о новой версии")
struct UpdateNotifierTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "notifier-tests-\(UUID().uuidString)")!
    }

    @MainActor
    private func makeService(
        current: String = "1.0.0",
        fetcher: FakeReleaseFetcher,
        notifier: SpyNotifier,
        defaults: UserDefaults? = nil
    ) -> UpdateService {
        UpdateService(
            currentVersion: AppVersion(current)!,
            fetcher: fetcher,
            installer: FakeInstaller(),
            terminator: FakeTerminator(),
            notifier: notifier,
            defaults: defaults ?? makeDefaults()
        )
    }

    private func release(_ version: String, notes: String = "Что нового") -> ReleaseInfo {
        ReleaseInfo(
            version: AppVersion(version)!,
            archiveURL: URL(string: "https://example.com/Проводник.zip")!,
            notes: notes,
            size: 1024
        )
    }

    // MARK: - Частота проверки

    @Test("проверка при запуске идёт в сеть, даже если проверка была только что")
    @MainActor
    func launchCheckIgnoresThrottle() async {
        // Смысл всей задачи: «включил приложение — узнал о новой версии».
        // Пока checkOnLaunch подчинялся суточному ограничению, второй за день
        // запуск приложения GitHub не спрашивал вовсе.
        let fetcher = FakeReleaseFetcher(release: release("1.1.0"))
        let defaults = makeDefaults()
        let service = makeService(fetcher: fetcher, notifier: SpyNotifier(), defaults: defaults)

        await service.checkOnLaunch()
        await service.checkOnLaunch()

        #expect(fetcher.callCount == 2)
    }

    @Test("суточное ограничение автопроверки осталось на месте")
    @MainActor
    func automaticCheckKeepsThrottle() async {
        // checkOnLaunch сняла ограничение только со своего пути: лимит GitHub —
        // 60 запросов в час на адрес, и для будущих периодических проверок
        // защита обязана сохраниться.
        let fetcher = FakeReleaseFetcher(release: release("1.1.0"))
        let defaults = makeDefaults()
        let service = makeService(fetcher: fetcher, notifier: SpyNotifier(), defaults: defaults)

        await service.checkAutomatically()
        await service.checkAutomatically()

        #expect(fetcher.callCount == 1)
    }

    // MARK: - Когда показывается баннер

    @Test("уведомляет о версии новее установленной")
    @MainActor
    func notifiesAboutNewerVersion() async {
        let notifier = SpyNotifier()
        let service = makeService(fetcher: FakeReleaseFetcher(release: release("1.1.0")), notifier: notifier)

        await service.checkOnLaunch()

        #expect(notifier.notifiedReleases.count == 1)
        #expect(notifier.notifiedReleases.first?.version == AppVersion("1.1.0")!)
    }

    @Test("не уведомляет, когда установлена последняя версия")
    @MainActor
    func staysSilentWhenUpToDate() async {
        let notifier = SpyNotifier()
        let service = makeService(fetcher: FakeReleaseFetcher(release: release("1.0.0")), notifier: notifier)

        await service.checkOnLaunch()

        #expect(notifier.notifiedReleases.isEmpty)
    }

    @Test("не уведомляет о релизе старее установленного")
    @MainActor
    func staysSilentAboutOlderRelease() async {
        let notifier = SpyNotifier()
        let service = makeService(fetcher: FakeReleaseFetcher(release: release("0.9.0")), notifier: notifier)

        await service.checkOnLaunch()

        #expect(notifier.notifiedReleases.isEmpty)
    }

    @Test("ручная проверка баннер не показывает, а не показывает его поверх поповера")
    @MainActor
    func manualCheckDoesNotNotify() async {
        // Нажавший «Проверить сейчас» смотрит в открытый поповер и результат
        // увидит там же. Системный баннер поверх него уведомлял бы человека
        // о том, что у него уже перед глазами.
        let notifier = SpyNotifier()
        let service = makeService(fetcher: FakeReleaseFetcher(release: release("1.1.0")), notifier: notifier)

        await service.checkManually()

        #expect(service.state == .available(release("1.1.0")))
        #expect(notifier.notifiedReleases.isEmpty)
    }

    @Test("неудачная проверка баннер не показывает")
    @MainActor
    func failedCheckDoesNotNotify() async {
        let notifier = SpyNotifier()
        let fetcher = FakeReleaseFetcher(error: URLError(.notConnectedToInternet))
        let service = makeService(fetcher: fetcher, notifier: notifier)

        await service.checkOnLaunch()

        #expect(notifier.notifiedReleases.isEmpty)
    }

    @Test("второй запуск с той же доступной версией уведомляет снова")
    @MainActor
    func notifiesOnEveryLaunch() async {
        // Выбранное поведение: напоминать при каждом запуске, пока человек не
        // обновился. Один раз на версию было бы тише, но про отложенное
        // обновление легко забыть совсем — синяя точка на чипе для этого
        // слишком незаметна, с неё вся задача и началась.
        let notifier = SpyNotifier()
        let defaults = makeDefaults()
        let service = makeService(
            fetcher: FakeReleaseFetcher(release: release("1.1.0")),
            notifier: notifier,
            defaults: defaults
        )

        await service.checkOnLaunch()
        // Перезапуск приложения: новый сервис на том же хранилище.
        let relaunched = makeService(
            fetcher: FakeReleaseFetcher(release: release("1.1.0")),
            notifier: notifier,
            defaults: defaults
        )
        await relaunched.checkOnLaunch()

        #expect(notifier.notifiedReleases.count == 2)
    }

    // MARK: - Разрешение

    @Test("запрос разрешения доходит до нотификатора")
    @MainActor
    func authorizationRequestReachesNotifier() async {
        let notifier = SpyNotifier()
        let service = makeService(fetcher: FakeReleaseFetcher(), notifier: notifier)

        await service.requestNotificationAuthorization()

        #expect(notifier.authorizationCount == 1)
    }

    @Test("проверка обновлений разрешения не спрашивает")
    @MainActor
    func checkDoesNotRequestAuthorization() async {
        // Разрешение — событие запуска процесса, а не проверки: спрашивать его
        // на каждой проверке значило бы дёргать систему без повода.
        let notifier = SpyNotifier()
        let service = makeService(fetcher: FakeReleaseFetcher(release: release("1.1.0")), notifier: notifier)

        await service.checkOnLaunch()

        #expect(notifier.authorizationCount == 0)
    }

    // MARK: - Обратный канал к поповеру

    @Test("клик по уведомлению поднимает запрос показа поповера, показ его сбрасывает")
    @MainActor
    func popoverRequestIsRaisedAndCleared() async {
        // Обратный канал «Core просит UI», как AppState.pendingRename: сервис
        // выставляет запрос, вью его исполняет и сбрасывает. Без сброса поповер
        // открывался бы заново на каждую перерисовку чипа.
        let service = makeService(fetcher: FakeReleaseFetcher(), notifier: SpyNotifier())

        #expect(service.showPopoverRequest == false)

        service.requestPopover()
        #expect(service.showPopoverRequest == true)

        service.popoverShown()
        #expect(service.showPopoverRequest == false)
    }

    // MARK: - Текст баннера

    @Test("телом баннера служит первая заметка новее установленной версии")
    func bodyUsesFirstNoteNewerThanCurrent() {
        // Тело релиза накопительное — в нём лежат и блоки прошлых выпусков.
        // Взяв первую строку всего тела без отбора, баннер рассказывал бы
        // о выпуске, который у человека давно установлен.
        let notes = """
        ## 1.1.0
        - Вкладки
        ## 1.0.0
        - Первый выпуск
        """
        let body = SystemUpdateNotifier.body(
            for: release("1.1.0", notes: notes),
            after: AppVersion("1.0.0")!
        )

        #expect(body == "Вкладки")
    }

    @Test("релиз без заметок даёт подсказку вместо пустого тела")
    func bodyFallsBackWhenNotesAreEmpty() {
        // Пустое тело у баннера выглядело бы как недорисованное уведомление.
        let body = SystemUpdateNotifier.body(
            for: release("1.1.0", notes: ""),
            after: AppVersion("1.0.0")!
        )

        #expect(body == "Нажмите, чтобы посмотреть, что изменилось.")
    }

    @Test("тело без заголовков версий разбирается плоским списком")
    func bodyHandlesNotesWithoutHeadings() {
        // Тело могли отредактировать руками и заголовки не поставить — секций
        // новее установленной не окажется вовсе, хотя пункты есть.
        let body = SystemUpdateNotifier.body(
            for: release("1.1.0", notes: "- Быстрая загрузка папок\n- Мелкие правки"),
            after: AppVersion("1.0.0")!
        )

        #expect(body == "Быстрая загрузка папок")
    }
}
