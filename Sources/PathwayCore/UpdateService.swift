import AppKit
import Foundation
import Observation

/// Что показывает значок в строке заголовка.
///
/// У `.failed` второй параметр — релиз, на загрузке которого упали, а `nil` —
/// упала именно проверка. Раньше этот релиз жил в отдельном приватном поле
/// сервиса рядом с `state`, и два значения могли рассинхронизироваться:
/// неудачная проверка не трогала поле, и `download()` после неё тихо повторял
/// загрузку старого релиза вместо новой проверки GitHub. Перенос релиза внутрь
/// самого случая делает такое рассогласование структурно невозможным — другого
/// источника правды для «что качать при повторе» просто не существует.
public enum UpdateState: Equatable, Sendable {
    /// Ещё не спрашивали. Отличается от `.upToDate` тем, что сказать человеку
    /// нечего: раньше оба случая сводились в `.idle`, и поповер не мог выбрать
    /// между «Установлена последняя версия» и молчанием — утверждать первое, ни
    /// разу не сходив на GitHub, он не вправе.
    case idle
    case checking
    /// Сходили и убедились: новее ничего нет.
    case upToDate
    case available(ReleaseInfo)
    /// Релиз рядом с долей загрузки: поповер пишет «Загрузка версии 1.1.0…», и
    /// без релиза в самом случае номер версии брать неоткуда — состояние
    /// `.available` к этому моменту уже затёрто.
    case downloading(ReleaseInfo, Double)
    /// Параметры — релиз и путь к проверенному бандлу, который ждёт подмены.
    /// Лежат внутри состояния по той же причине, что и релиз у `.failed`:
    /// отдельное поле рядом с `state` — это второй источник правды, который уже
    /// однажды разошёлся с первым. Пока путь живёт в самом случае, «готово к
    /// перезапуску без подготовленного бандла» невыразимо, а не просто
    /// маловероятно.
    case readyToRestart(ReleaseInfo, URL)
    case failed(String, ReleaseInfo?)
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

    /// Когда GitHub отвечал в последний раз — подвал поповера пишет «Проверено
    /// в 21:59». Наблюдаемое свойство, а не чтение `UserDefaults` из вью:
    /// значение меняется во время работы, и вью обязано перерисоваться само.
    /// Хранилище то же самое, что у ограничения раз в сутки, — иначе появились
    /// бы две даты последней проверки, расходящиеся при первой же неудаче.
    public private(set) var lastCheck: Date?

    /// Обратный канал «Core просит UI»: поднят — значит поповер версии нужно
    /// раскрыть. Тот же приём, что у `AppState.pendingRename`; поднимает его
    /// делегат приложения, поймавший клик по баннеру уведомления, а сбрасывает
    /// вью в момент показа.
    ///
    /// `Bool`, а не счётчик: повторный клик по тому же баннеру при уже открытом
    /// поповере ничего делать не должен, и сброс на показе даёт это даром.
    public private(set) var showPopoverRequest = false

    private let fetcher: any ReleaseFetching
    private let installer: any UpdateInstalling
    private let terminator: any AppTerminating
    private let notifier: any UpdateNotifying
    private let defaults: UserDefaults
    private let session: URLSession

    private static let lastCheckKey = "lastUpdateCheck"
    /// Реже суток проверять незачем, чаще — незачем тем более: лимит GitHub без
    /// авторизации 60 запросов в час на адрес, и все коллеги могут сидеть за одним NAT.
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    /// `notifier` по умолчанию nil, а не готовый `SystemUpdateNotifier`:
    /// боевому нотификатору нужна текущая версия, а она выясняется здесь же, из
    /// Info.plist. Значение по умолчанию вычислялось бы до этого момента и не
    /// имело бы к ней доступа, поэтому подстановка отложена в тело init.
    public init(
        currentVersion: AppVersion? = nil,
        fetcher: any ReleaseFetching = GitHubReleaseFetcher(),
        installer: any UpdateInstalling = BundleUpdateInstaller(),
        terminator: any AppTerminating = AppKitTerminator(),
        notifier: (any UpdateNotifying)? = nil,
        defaults: UserDefaults = .standard,
        session: URLSession = .shared
    ) {
        let bundled = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let version = currentVersion ?? bundled.flatMap(AppVersion.init) ?? AppVersion("0.0.0")!
        self.currentVersion = version
        self.fetcher = fetcher
        self.installer = installer
        self.terminator = terminator
        self.notifier = notifier ?? SystemUpdateNotifier(currentVersion: version)
        self.defaults = defaults
        self.session = session
        self.lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    // MARK: - Проверка

    /// Проверка при старте процесса. Ограничение суток не соблюдает намеренно:
    /// запуск приложения случается редко, и человек в этот момент ждёт свежих
    /// данных. Пока эта проверка ходила через `checkAutomatically`, второй за
    /// день запуск GitHub не спрашивал вовсе — «включил приложение и узнал
    /// о новой версии» не работало.
    public func checkOnLaunch() async {
        await check(silent: true, notifyOnFind: true)
    }

    /// Периодическая проверка — не чаще раза в сутки. Неудача остаётся
    /// незамеченной. Сейчас её никто не зовёт: она осталась готовой к фоновой
    /// проверке во время работы приложения, где лимит GitHub (60 запросов в час
    /// на адрес, а коллеги могут сидеть за одним NAT) снова станет важен.
    public func checkAutomatically() async {
        guard shouldCheckNow else { return }
        await check(silent: true, notifyOnFind: true)
    }

    /// Проверка по просьбе пользователя: игнорирует ограничение и показывает ошибку.
    ///
    /// Баннер не показывает: человек нажал «Проверить сейчас» в открытом
    /// поповере и результат увидит там же — системное уведомление поверх него
    /// сообщало бы о том, что уже перед глазами.
    public func checkManually() async {
        await check(silent: false, notifyOnFind: false)
    }

    /// Разовый запрос разрешения на уведомления. Зовётся делегатом приложения
    /// при запуске: разрешение — событие процесса, а не проверки обновлений.
    ///
    /// Своего флага «уже спрашивали» нет. `UNUserNotificationCenter` показывает
    /// системный диалог ровно один раз и при повторных вызовах молча возвращает
    /// принятое решение; флаг в `UserDefaults` был бы вторым источником правды
    /// о том, что система и так помнит, и разошёлся бы с ней при сбросе
    /// разрешений в Настройках.
    public func requestNotificationAuthorization() async {
        await notifier.requestAuthorization()
    }

    // MARK: - Обратный канал к поповеру

    /// Просьба раскрыть поповер версии — приходит от делегата приложения,
    /// поймавшего клик по баннеру уведомления.
    public func requestPopover() {
        showPopoverRequest = true
    }

    /// Поповер раскрыт, просьба исполнена. Без сброса вью открывало бы его
    /// заново на каждой перерисовке чипа.
    public func popoverShown() {
        showPopoverRequest = false
    }

    private var shouldCheckNow: Bool {
        guard let lastCheck else { return true }
        return Date().timeIntervalSince(lastCheck) >= Self.checkInterval
    }

    private func check(silent: Bool, notifyOnFind: Bool) async {
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
            let now = Date()
            defaults.set(now, forKey: Self.lastCheckKey)
            lastCheck = now
            guard let release, release.version > currentVersion else {
                state = .upToDate
                return
            }
            state = .available(release)
            // `await`, а не `Task { }` без ожидания: последнее превратило бы
            // проверку «уведомил про найденную версию» в гонку. Задержки на
            // глаз нет — `UNUserNotificationCenter.add` возвращается сразу,
            // доставку система берёт на себя.
            if notifyOnFind { await notifier.notify(about: release) }
        } catch {
            // Нет сети — обычное дело, и само по себе не повод беспокоить человека.
            // Сказать стоит только тому, кто проверку и запросил.
            // Второй параметр — nil: упала именно проверка, релиза для повтора
            // загрузки нет и появиться ему неоткуда, кроме новой проверки.
            state = silent ? .idle : .failed(error.localizedDescription, nil)
        }
    }

    // MARK: - Загрузка и установка

    /// Скачивает обновление и готовит подмену бандла.
    ///
    /// Работает и из `.available` (первая попытка), и из `.failed` с релизом
    /// внутри (повтор после сбоя сети или установки) — второе намеренно: без
    /// него пользователю после одной неудачной загрузки пришлось бы заново
    /// проходить проверку обновлений ради того же самого релиза. Если же в
    /// `.failed` релиза нет (упала проверка, а не загрузка), повторять нечего —
    /// `download()` не имеет права угадывать релиз из ниоткуда, нужна новая
    /// проверка GitHub.
    public func download() async {
        let release: ReleaseInfo
        switch state {
        case .available(let available):
            release = available
        case .failed(_, .some(let previous)):
            release = previous
        default:
            return
        }
        state = .downloading(release, 0)

        do {
            let archive = try await downloadArchive(release)
            // Только подготовка: распаковать и проверить. Скрипт подмены здесь не
            // запускается — он отмеряет на закрытие приложения десять секунд, а
            // между этим моментом и нажатием «Перезапустить» проходит сколько
            // угодно времени. Запуск перенесён в restart().
            let prepared = try installer.prepare(archive: archive)
            state = .readyToRestart(release, prepared)
        } catch {
            // Релиз — тот же самый, на котором упали: сохраняем его в состоянии,
            // а не в отдельном поле, иначе следующая неудачная проверка не смогла
            // бы его стереть и повтор загрузки взял бы устаревшие данные.
            state = .failed(error.localizedDescription, release)
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
        // Релиз нужен не только ради архива: reportProgress кладёт его в
        // .downloading, чтобы поповер мог назвать загружаемую версию.
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
                reportProgress(release: release, written: written, expected: expected, lastShown: &lastShown)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += buffer.count
            reportProgress(release: release, written: written, expected: expected, lastShown: &lastShown)
        }

        return archive
    }

    /// Обновляет `state` шагом примерно в процент — перерисовывать значок на
    /// каждый чанк незачем: шаг незаметен глазу, а обновление @Observable на
    /// каждой итерации стоит дорого.
    private func reportProgress(
        release: ReleaseInfo,
        written: Int,
        expected: Int64,
        lastShown: inout Double
    ) {
        // expected может быть 0 (сервер не прислал Content-Length, а размер
        // релиза в ReleaseInfo не заполнен) — без защиты деление дало бы NaN,
        // и .downloading(.nan) сломал бы отрисовку прогресс-бара.
        guard expected > 0 else { return }
        let progress = Double(written) / Double(expected)
        if progress - lastShown >= 0.01 {
            lastShown = progress
            state = .downloading(release, min(progress, 1))
        }
    }

    /// Запускает подмену бандла и закрывает приложение — дальше работает
    /// скрипт-помощник.
    ///
    /// Порядок именно такой: скрипт первым делом ждёт исчезновения процесса, и
    /// стартовать он обязан до `terminate`, а не после — после нас звать его
    /// уже некому. Отсчёт ожидания начинается здесь, поэтому в десять секунд
    /// укладывается обычное закрытие приложения, а не раздумья человека.
    public func restart() {
        guard case .readyToRestart(_, let bundle) = state else { return }

        do {
            try installer.launchInstaller(bundle: bundle)
        } catch {
            // Приложение не закрываем: скрипт не стартовал, подменять бандл
            // некому, и закрытие оставило бы человека без обновления и без
            // объяснения. Релиз в .failed кладём nil в обоих случаях сбоя:
            // если скрипт не запустился — архив ещё цел, но подождавший в
            // очереди уже переспрошен смысла не имеет; если подготовленный
            // бандл пропал из TMPDIR за часы простоя (preparedBundleMissing) —
            // от архива тоже могло ничего не остаться. И там, и там повторять
            // нужно проверку обновлений заново, а не тянуть за собой старый релиз.
            state = .failed(error.localizedDescription, nil)
            return
        }
        terminator.terminate()
    }
}
