import Foundation

/// Пороги поиска. Значения — правила, а не оформление, поэтому живут в Core.
public struct SearchLimits: Sendable {
    /// Порог размера архива на локальном диске.
    public let localArchiveBytes: Int64
    /// Порог размера архива на сетевом томе — строже: там архив тянется по
    /// сети целиком, а обход одной записи стоит около 9 мс (замер на FTP).
    public let networkArchiveBytes: Int64
    /// Предел записей на архив — защита памяти, не скорости.
    public let entriesPerArchive: Int
    /// Одновременно вскрываемых архивов. Замер дал 6,8× на восьми задачах;
    /// больше не ускоряет, а на сетевом томе забивает канал.
    public let concurrentArchives: Int

    public init(
        localArchiveBytes: Int64 = 500_000_000,
        networkArchiveBytes: Int64 = 50_000_000,
        entriesPerArchive: Int = ZipCentralDirectory.defaultLimit,
        concurrentArchives: Int = 8
    ) {
        self.localArchiveBytes = localArchiveBytes
        self.networkArchiveBytes = networkArchiveBytes
        self.entriesPerArchive = entriesPerArchive
        self.concurrentArchives = concurrentArchives
    }
}

/// Архив, который поиск не открыл, и почему.
public struct SkippedArchive: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let sizeBytes: Int64

    public init(url: URL, sizeBytes: Int64) {
        self.url = url
        self.sizeBytes = sizeBytes
    }
}

/// Итог поиска: что не удалось посмотреть.
///
/// Не ошибка: одна нечитаемая папка или битый архив не должны отменять весь
/// поиск. Но и молчать нельзя — пользователь обязан знать, что выдача неполна.
public struct SearchReport: Equatable, Sendable {
    public var skipped: [SkippedArchive] = []
    public var failed: [URL] = []
    public var isComplete: Bool { skipped.isEmpty && failed.isEmpty }

    public init(skipped: [SkippedArchive] = [], failed: [URL] = []) {
        self.skipped = skipped
        self.failed = failed
    }
}

/// Ход поиска: сколько просмотрено и какая часть работы позади.
///
/// Общего числа файлов заранее нет — чтобы его узнать, надо обойти папку, то
/// есть проделать всю работу. Поэтому доля считается по двум фазам, у каждой
/// свой знаменатель:
///
/// - обход (0–50 %) — папки: обойдено / (обойдено + осталось в очереди);
/// - архивы (50–100 %) — вскрыто / всего, знаменатель точный.
///
/// Половина на фазу — допущение, и оно намеренно грубое. Соотношение реального
/// времени зависит от того, сколько архивов попалось и лежат ли они в сети;
/// подгонять веса значило бы выдавать догадку за измерение. Единственное
/// уточнение — папка без архивов: там обход и есть вся работа, он занимает всю
/// полосу.
public struct SearchProgress: Equatable, Sendable {
    /// Просмотрено имён на диске.
    public var scannedFiles = 0
    /// Обойдено папок.
    public var scannedDirectories = 0
    /// Папок в очереди на обход. Ноль по завершении обхода.
    public var queuedDirectories = 0
    /// Вскрыто архивов.
    public var scannedArchives = 0
    /// Всего архивов к вскрытию. Известно только после обхода: до тех пор 0.
    public var totalArchives = 0
    /// Обход завершён — дальше идут только архивы.
    public var walkFinished = false

    public init(
        scannedFiles: Int = 0,
        scannedDirectories: Int = 0,
        queuedDirectories: Int = 0,
        scannedArchives: Int = 0,
        totalArchives: Int = 0,
        walkFinished: Bool = false
    ) {
        self.scannedFiles = scannedFiles
        self.scannedDirectories = scannedDirectories
        self.queuedDirectories = queuedDirectories
        self.scannedArchives = scannedArchives
        self.totalArchives = totalArchives
        self.walkFinished = walkFinished
    }

    /// Доля выполненного, 0…1.
    ///
    /// Оценка, а не измерение: знаменатель первой фазы уточняется по ходу.
    /// Убывание гасит `SearchModel`, а не эта функция, — здесь честное текущее
    /// значение, и тесты проверяют именно его.
    public var fraction: Double {
        // Обхода ещё не было: показывать нечего, но и ноль честнее выдуманного
        // числа.
        guard scannedDirectories > 0 || walkFinished else { return 0 }

        // Папка без архивов: обход — вся работа, растягиваем его на полосу
        // целиком. Иначе поиск в обычной папке замирал бы на половине.
        let walkWeight = (walkFinished && totalArchives == 0) ? 1.0 : 0.5

        let walkPart: Double
        if walkFinished {
            walkPart = walkWeight
        } else {
            let total = Double(scannedDirectories + queuedDirectories)
            let done = total > 0 ? Double(scannedDirectories) / total : 0
            // Потолок 0,98 доли фазы: пустая очередь на последней порции даёт
            // ровно единицу, и полоса вставала бы на 50 % лишним кадром — а
            // архивы к этому моменту ещё не сосчитаны, и вдруг их нет вовсе.
            // Тогда следующий же кадр прыгнул бы с 50 % на 100 %.
            walkPart = min(done, 0.98) * walkWeight
        }

        guard totalArchives > 0 else { return walkPart }
        let archivePart = Double(scannedArchives) / Double(totalArchives) * (1 - walkWeight)
        return min(1, walkPart + archivePart)
    }
}

/// Событие поиска. Результаты идут порциями, а не одним ответом: обычные файлы
/// находятся за миллисекунды, и ждать самый медленный архив ради первой строки
/// пользователю незачем.
public enum SearchEvent: Sendable {
    case results([SearchResult])
    case progress(SearchProgress)
    case finished(SearchReport)
}

/// Поиск по файлам и внутри архивов.
///
/// Конвейер из двух потоков работы. Первый обходит каталог через
/// `opendir`/`readdir` и сразу отдаёт совпавшие имена. Второй параллельно
/// вскрывает найденные архивы и отдаёт совпавшие записи. Оба пишут в один
/// поток событий, поэтому список наполняется непрерывно.
/// Движок — не актор намеренно.
///
/// Изоляция всего движка сериализовала бы вскрытие архивов: каждая задача
/// ждала бы освобождения актора, и «параллельные» восемь исполнялись бы по
/// очереди. Замер на 209 архивах: 1744 мс через актор против 20 мс без него —
/// в 87 раз, целиком за счёт ожидания на изоляции.
///
/// Изменяемое состояние — только кэш оглавлений, и он вынесен в собственный
/// актор: короткие обращения к словарю сериализовать не жалко, а чтение
/// архивов идёт мимо него.
public final class SearchEngine: Sendable {
    private let listing: any ArchiveListing
    private let limits: SearchLimits
    private let isNetworkVolume: @Sendable (URL) -> Bool
    private let cache = ListingCache()

    public init(
        listing: any ArchiveListing = SystemArchiveListing(),
        limits: SearchLimits = SearchLimits(),
        isNetworkVolume: @escaping @Sendable (URL) -> Bool = volumeIsNetwork
    ) {
        self.listing = listing
        self.limits = limits
        self.isNetworkVolume = isNetworkVolume
    }

    /// Запускает поиск. Поток завершается сам по исчерпании работы или отмене.
    public func search(
        query: String,
        in directory: URL,
        ignoringSizeLimit: Bool = false
    ) -> AsyncStream<SearchEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.run(
                    query: query, directory: directory,
                    ignoringSizeLimit: ignoringSizeLimit, continuation: continuation
                )
                continuation.finish()
            }
            // Отмена потребителем обязана снимать работу: иначе брошенный поиск
            // продолжал бы тянуть архивы по сети в пустоту.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        query: String,
        directory: URL,
        ignoringSizeLimit: Bool,
        continuation: AsyncStream<SearchEvent>.Continuation
    ) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            continuation.yield(.finished(SearchReport()))
            return
        }

        // Свёртка запроса готовится один раз на весь поиск: она не зависит от
        // имени, а имён — десятки тысяч.
        let needle = FuzzyMatcher.Query(trimmed)

        var report = SearchReport()
        let sizeLimit = ignoringSizeLimit
            ? Int64.max
            : (isNetworkVolume(directory) ? limits.networkArchiveBytes : limits.localArchiveBytes)

        // Первый проход: имена с диска. Сопоставление идёт **по ходу обхода**, а
        // не после него: обход сетевой папки с тысячами каталогов занимает
        // секунды, и результат, собранный целиком, показался бы одним рывком в
        // конце — ровно то, что выглядит как зависание.
        var archives: [URL] = []
        var progress = SearchProgress()
        DirectoryWalk.walk(root: directory, isCancelled: { Task.isCancelled }) { batch in
            archives.append(contentsOf: batch.archives)
            progress.scannedFiles += batch.files.count
            progress.scannedDirectories += 1
            progress.queuedDirectories = batch.queuedDirectories

            let matches = batch.files.compactMap { file -> SearchResult? in
                guard let match = FuzzyMatcher.match(query: needle, in: file.name) else { return nil }
                return SearchResult(
                    url: file.url, name: file.name, source: .file,
                    score: match.score, matchedIndices: match.matchedIndices,
                    isDirectory: file.isDirectory
                )
            }
            if !matches.isEmpty { continuation.yield(.results(Self.rank(matches))) }
            continuation.yield(.progress(progress))
        }
        progress.walkFinished = true
        progress.queuedDirectories = 0
        if Task.isCancelled { continuation.yield(.finished(report)); return }

        // Второй проход: архивы. Пропущенные по размеру собираются до запуска
        // задач, чтобы не платить за них ни одной операцией ввода-вывода.
        var openable: [URL] = []
        for archive in archives {
            let size = Self.fileSize(archive)
            if size > sizeLimit {
                report.skipped.append(SkippedArchive(url: archive, sizeBytes: size))
            } else {
                openable.append(archive)
            }
        }
        progress.totalArchives = openable.count
        continuation.yield(.progress(progress))

        let failures = await withTaskGroup(of: (URL, [SearchResult]?).self) { group in
            var failed: [URL] = []
            var index = 0

            func addTask(_ archive: URL) {
                group.addTask {
                    guard let names = try? await self.entries(of: archive) else { return (archive, nil) }
                    let matches = names.compactMap { path -> SearchResult? in
                        let name = (path as NSString).lastPathComponent
                        guard let match = FuzzyMatcher.match(query: needle, in: name) else { return nil }
                        return SearchResult(
                            url: archive, name: name, source: .archiveEntry(path: path),
                            score: match.score, matchedIndices: match.matchedIndices
                        )
                    }
                    return (archive, matches)
                }
            }

            // Окно задач фиксированной ширины: запускать сразу тысячу — значит
            // открыть тысячу процессов и соединений разом.
            while index < openable.count, index < limits.concurrentArchives {
                addTask(openable[index])
                index += 1
            }

            while let (archive, matches) = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                if let matches {
                    if !matches.isEmpty { continuation.yield(.results(Self.rank(matches))) }
                } else {
                    failed.append(archive)
                }
                progress.scannedArchives += 1
                continuation.yield(.progress(progress))
                if index < openable.count {
                    addTask(openable[index])
                    index += 1
                }
            }
            return failed
        }

        report.failed = failures
        continuation.yield(.finished(report))
    }

    /// Оглавление архива с кэшированием на сеанс.
    ///
    /// Кэш спрашивается и заполняется двумя короткими обращениями к актору, а
    /// само чтение архива идёт **между** ними, вне изоляции — иначе долгий
    /// `bsdtar` держал бы актор и обессмысливал параллелизм.
    ///
    /// Гонка двух задач на одном архиве возможна: обе не найдут его в кэше и
    /// прочитают дважды. Это дешевле блокировки — в пределах одного поиска
    /// архив встречается один раз, а повторное чтение стоит миллисекунды.
    private func entries(of archive: URL) async throws -> [String] {
        let key = ListingCache.Key(archive)
        if let cached = await cache.value(for: key) { return cached }
        let names = try await listing.entryNames(of: archive, limit: limits.entriesPerArchive)
        await cache.store(names, for: key)
        return names
    }

    // MARK: - Вспомогательное

    private static func rank(_ results: [SearchResult]) -> [SearchResult] {
        results.sorted { ($0.score, $1.name) > ($1.score, $0.name) }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}

/// Оглавления архивов, прочитанные в этом сеансе.
///
/// Ключ включает размер и дату изменения: пересобранный архив обязан быть
/// перечитан, иначе поиск отдавал бы состав вчерашнего. Только в памяти —
/// дисковый кэш потребовал бы инвалидации, миграций и чистки ради выигрыша во
/// втором запуске подряд.
private actor ListingCache {
    struct Key: Hashable {
        let path: String
        let size: Int64
        let modified: TimeInterval

        init(_ archive: URL) {
            let values = try? archive.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            path = archive.path
            size = Int64(values?.fileSize ?? 0)
            modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        }
    }

    private var entries: [Key: [String]] = [:]

    func value(for key: Key) -> [String]? { entries[key] }
    func store(_ names: [String], for key: Key) { entries[key] = names }
}

/// Том сетевой.
///
/// На уровне файла, а не в типе: значение по умолчанию в инициализаторе не
/// может ссылаться на член собственного типа. Подменяемость важнее — иначе
/// пороги размера проверялись бы только на машине с примонтированным сетевым
/// диском, то есть на практике никогда.
public func volumeIsNetwork(_ url: URL) -> Bool {
    !((try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? true)
}
