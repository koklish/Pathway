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
        // Пока идёт скачивание или проверка, проверять нечего — иначе состояние
        // перетрётся, а повторный клик по «Проверить обновления» запустит
        // параллельный запрос к GitHub с гонкой за финальный state.
        if case .checking = state { return }
        if case .downloading = state { return }
        if case .readyToRestart = state { return }

        state = .checking

        do {
            let release = try await fetcher.latestRelease()
            // Дата пишется только тут, после успешного ответа: неудачная
            // проверка не должна засчитываться как состоявшаяся — иначе
            // приложение, однажды не достучавшееся до сети, замолкало бы
            // на сутки, хотя ни разу не проверило обновления по-настоящему.
            defaults.set(Date(), forKey: Self.lastCheckKey)
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

    /// Релиз последней (неудавшейся) загрузки — чтобы `download()` можно было
    /// повторить прямо из `.failed`, не гоняя пользователя через новую проверку
    /// GitHub за тем же самым релизом, который уже известен.
    private var lastAttemptedRelease: ReleaseInfo?

    /// Скачивает обновление и готовит подмену бандла.
    ///
    /// Работает и из `.available` (первая попытка), и из `.failed` (повтор после
    /// сбоя сети или установки) — второе намеренно: без него пользователю после
    /// одной неудачной загрузки пришлось бы заново проходить проверку обновлений
    /// ради того же самого релиза.
    public func download() async {
        let release: ReleaseInfo
        switch state {
        case .available(let available):
            release = available
        case .failed where lastAttemptedRelease != nil:
            release = lastAttemptedRelease!
        default:
            return
        }
        lastAttemptedRelease = release
        state = .downloading(0)

        do {
            let archive = try await downloadArchive(release)
            try installer.install(archive: archive)
            state = .readyToRestart
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Размер чанка на запись: 64 КБ. `URLSession.AsyncBytes` отдаёт байты
    /// только по одному — возобновление итератора на каждый байт неизбежно
    /// при этом API, — но старый код вдобавок звал `Data.append` и держал
    /// весь архив в памяти на каждый байт. Копим байты в чанк и одним вызовом
    /// дописываем в файл через FileHandle: `append` вызывается тысячи раз, а
    /// не миллионы, и в памяти живёт только текущий чанк, а не весь архив.
    private static let chunkSize = 64 * 1024

    private func downloadArchive(_ release: ReleaseInfo) async throws -> URL {
        let (bytes, response) = try await session.bytes(from: release.archiveURL)
        let expected = response.expectedContentLength > 0
            ? response.expectedContentLength : release.size

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathwayUpdate", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let archive = directory.appendingPathComponent("update.zip")
        guard FileManager.default.createFile(atPath: archive.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: archive)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(Self.chunkSize)
        var written = 0
        var lastShown = 0.0

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= Self.chunkSize {
                try handle.write(contentsOf: buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)
                reportProgress(written: written, expected: expected, lastShown: &lastShown)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += buffer.count
            reportProgress(written: written, expected: expected, lastShown: &lastShown)
        }

        return archive
    }

    /// Обновляет `state` шагом примерно в процент — перерисовывать значок на
    /// каждый чанк незачем: шаг незаметен глазу, а обновление @Observable на
    /// каждой итерации стоит дорого.
    private func reportProgress(written: Int, expected: Int64, lastShown: inout Double) {
        // expected может быть 0 (сервер не прислал Content-Length, а размер
        // релиза в ReleaseInfo не заполнен) — без защиты деление дало бы NaN,
        // и .downloading(.nan) сломал бы отрисовку прогресс-бара.
        guard expected > 0 else { return }
        let progress = Double(written) / Double(expected)
        if progress - lastShown >= 0.01 {
            lastShown = progress
            state = .downloading(min(progress, 1))
        }
    }

    /// Закрывает приложение — дальше работает скрипт-помощник.
    public func restart() {
        NSApp.terminate(nil)
    }
}
