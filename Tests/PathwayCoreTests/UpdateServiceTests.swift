import Foundation
import Testing

@testable import PathwayCore

/// Подменяет GitHub: отдаёт заданный релиз и считает обращения.
final class FakeReleaseFetcher: ReleaseFetching, @unchecked Sendable {
    var release: ReleaseInfo?
    var error: (any Error)?
    private(set) var callCount = 0

    init(release: ReleaseInfo? = nil, error: (any Error)? = nil) {
        self.release = release
        self.error = error
    }

    func latestRelease() async throws -> ReleaseInfo? {
        callCount += 1
        if let error { throw error }
        return release
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

private func makeRelease(_ version: String) -> ReleaseInfo {
    ReleaseInfo(
        version: AppVersion(version)!,
        archiveURL: URL(string: "https://example.com/Проводник.zip")!,
        notes: "Что нового",
        size: 1024
    )
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
        defaults: UserDefaults? = nil
    ) -> UpdateService {
        UpdateService(
            currentVersion: AppVersion(current)!,
            fetcher: fetcher,
            installer: installer,
            defaults: defaults ?? makeDefaults()
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

        guard case .failed = service.state else {
            Issue.record("ожидалось состояние .failed, получено \(service.state)")
            return
        }
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

    @Test("отсутствие релизов не считается ошибкой")
    @MainActor
    func noReleasesIsNotAnError() async {
        let service = makeService(fetcher: FakeReleaseFetcher(release: nil))

        await service.checkManually()

        #expect(service.state == .idle)
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
