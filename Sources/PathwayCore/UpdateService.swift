import AppKit
import Foundation
import Observation

/// Что показывает значок в строке заголовка.
public enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case available(ReleaseInfo)
    case downloading(Double)
    case readyToRestart
    case failed(String)
}

/// Проверка и установка обновлений.
///
/// Знает, когда стоит спрашивать GitHub и что показать пользователю; как именно
/// добывается релиз и как он ставится — дело ReleaseFetching и UpdateInstalling.
@Observable
@MainActor
public final class UpdateService {
    public private(set) var state: UpdateState = .idle
    public let currentVersion: AppVersion

    private let fetcher: any ReleaseFetching
    private let installer: any UpdateInstalling
    private let defaults: UserDefaults
    private let session: URLSession

    private static let lastCheckKey = "lastUpdateCheck"
    /// Реже суток проверять незачем, чаще — незачем тем более: лимит GitHub без
    /// авторизации 60 запросов в час на адрес, и все коллеги могут сидеть за одним NAT.
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    public init(
        currentVersion: AppVersion? = nil,
        fetcher: any ReleaseFetching = GitHubReleaseFetcher(),
        installer: any UpdateInstalling = BundleUpdateInstaller(),
        defaults: UserDefaults = .standard,
        session: URLSession = .shared
    ) {
        let bundled = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        self.currentVersion = currentVersion ?? bundled.flatMap(AppVersion.init) ?? AppVersion("0.0.0")!
        self.fetcher = fetcher
        self.installer = installer
        self.defaults = defaults
        self.session = session
    }

    // MARK: - Проверка

    /// Проверка при запуске и раз в сутки. Неудача остаётся незамеченной.
    public func checkAutomatically() async {
        guard shouldCheckNow else { return }
        await check(silent: true)
    }

    /// Проверка по просьбе пользователя: игнорирует ограничение и показывает ошибку.
    public func checkManually() async {
        await check(silent: false)
    }

    private var shouldCheckNow: Bool {
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date
        guard let last else { return true }
        return Date().timeIntervalSince(last) >= Self.checkInterval
    }

    private func check(silent: Bool) async {
        // Пока идёт скачивание, проверять нечего — иначе состояние перетрётся.
        if case .downloading = state { return }
        if case .readyToRestart = state { return }

        state = .checking
        defaults.set(Date(), forKey: Self.lastCheckKey)

        do {
            let release = try await fetcher.latestRelease()
            guard let release, release.version > currentVersion else {
                state = .idle
                return
            }
            state = .available(release)
        } catch {
            // Нет сети — обычное дело, и само по себе не повод беспокоить человека.
            // Сказать стоит только тому, кто проверку и запросил.
            state = silent ? .idle : .failed(error.localizedDescription)
        }
    }

    // MARK: - Загрузка и установка

    /// Скачивает обновление и готовит подмену бандла.
    public func download() async {
        guard case .available(let release) = state else { return }
        state = .downloading(0)

        do {
            let archive = try await downloadArchive(release)
            try installer.install(archive: archive)
            state = .readyToRestart
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func downloadArchive(_ release: ReleaseInfo) async throws -> URL {
        let (bytes, response) = try await session.bytes(from: release.archiveURL)
        let expected = response.expectedContentLength > 0
            ? response.expectedContentLength : release.size

        var data = Data()
        data.reserveCapacity(Int(expected))
        var lastShown = 0.0
        for try await byte in bytes {
            data.append(byte)
            let progress = Double(data.count) / Double(expected)
            // Перерисовывать значок на каждый байт незачем: шаг в процент незаметен
            // глазу, а обновление @Observable на каждой итерации стоит дорого.
            if progress - lastShown >= 0.01 {
                lastShown = progress
                state = .downloading(min(progress, 1))
            }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathwayUpdate", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let archive = directory.appendingPathComponent("update.zip")
        try data.write(to: archive)
        return archive
    }

    /// Закрывает приложение — дальше работает скрипт-помощник.
    public func restart() {
        NSApp.terminate(nil)
    }
}
