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

/// Пороги поиска по содержимому.
///
/// Отдельно от `SearchLimits` намеренно: 500 МБ архива читаются по оглавлению в
/// хвосте — килобайты ввода-вывода, а 500 МБ текста нужно прочитать целиком.
/// Одно число на две несравнимые операции душило бы одну ради другой.
public struct ContentSearchLimits: Sendable {
    /// Порог размера читаемого файла на локальном диске.
    public let localFileBytes: Int64
    /// Порог размера читаемого файла на сетевом томе — строже: файл тянется по
    /// сети целиком, и его размер прямо переводится в время ожидания.
    public let networkFileBytes: Int64
    /// Порог размера архива, распаковываемого ради содержимого. Считается от
    /// архива, а не записи: распакованное занимает место на диске, и ограничивать
    /// нужно то, что реально тратится.
    public let localArchiveBytes: Int64
    public let networkArchiveBytes: Int64
    /// Одновременно читаемых файлов. Шире архивного окна: чтение файла легче
    /// распаковки, и держать их на одном числе значило бы душить одно ради
    /// другого.
    public let concurrentReads: Int

    public init(
        localFileBytes: Int64 = 20_000_000,
        networkFileBytes: Int64 = 5_000_000,
        localArchiveBytes: Int64 = 50_000_000,
        networkArchiveBytes: Int64 = 10_000_000,
        concurrentReads: Int = 12
    ) {
        self.localFileBytes = localFileBytes
        self.networkFileBytes = networkFileBytes
        self.localArchiveBytes = localArchiveBytes
        self.networkArchiveBytes = networkArchiveBytes
        self.concurrentReads = concurrentReads
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

/// Файл, содержимое которого поиск не прочитал из-за размера.
public struct SkippedFile: Identifiable, Hashable, Sendable {
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
    /// Файлы, чьё содержимое не прочитано из-за размера. Отдельный список, а не
    /// общий со `skipped`: строка внизу выдачи должна называть вещи своими
    /// именами — «3 архива и 12 файлов не просмотрены» понятнее, чем «15
    /// объектов».
    public var skippedFiles: [SkippedFile] = []
    public var failed: [URL] = []
    public var isComplete: Bool { skipped.isEmpty && skippedFiles.isEmpty && failed.isEmpty }

    public init(
        skipped: [SkippedArchive] = [],
        skippedFiles: [SkippedFile] = [],
        failed: [URL] = []
    ) {
        self.skipped = skipped
        self.skippedFiles = skippedFiles
        self.failed = failed
    }
}

/// Ход поиска: сколько просмотрено и какая часть работы позади.
///
/// Общего числа файлов заранее нет — чтобы его узнать, надо обойти папку, то
/// есть проделать всю работу. Поэтому доля считается по двум фазам, у каждой
/// свой знаменатель:
///
/// - обход — папки: обойдено / (обойдено + осталось в очереди);
/// - архивы — вскрыто / всего, знаменатель точный;
/// - содержимое — прочитано / всего, знаменатель точный.
///
/// Веса зависят от режима:
///
/// | режим | обход | архивы | содержимое |
/// |---|---|---|---|
/// | только имена | 0–50 % | 50–100 % | — |
/// | с содержимым | 0–20 % | 20–30 % | 30–100 % |
///
/// Числа — допущение, и оно намеренно грубое. Соотношение реального времени
/// зависит от того, сколько попалось архивов и читаемых файлов и лежат ли они в
/// сети; подгонять веса значило бы выдавать догадку за измерение. Единственное
/// уточнение — фаза, которой не досталось работы: её доля переходит предыдущей,
/// иначе поиск в папке без архивов замирал бы на половине.
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
    /// Прочитано файлов ради содержимого.
    public var readFiles = 0
    /// Всего файлов к прочтению. Известно только после обхода: до тех пор 0.
    public var totalReadableFiles = 0
    /// Режим чтения содержимого включён — от этого зависят веса полосы.
    public var searchesContent = false

    public init(
        scannedFiles: Int = 0,
        scannedDirectories: Int = 0,
        queuedDirectories: Int = 0,
        scannedArchives: Int = 0,
        totalArchives: Int = 0,
        walkFinished: Bool = false,
        readFiles: Int = 0,
        totalReadableFiles: Int = 0,
        searchesContent: Bool = false
    ) {
        self.scannedFiles = scannedFiles
        self.scannedDirectories = scannedDirectories
        self.queuedDirectories = queuedDirectories
        self.scannedArchives = scannedArchives
        self.totalArchives = totalArchives
        self.walkFinished = walkFinished
        self.readFiles = readFiles
        self.totalReadableFiles = totalReadableFiles
        self.searchesContent = searchesContent
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

        // Веса фаз, у которых есть работа. Знать это можно только после обхода:
        // до тех пор архивы и файлы не сосчитаны, и обход берёт свою долю по
        // режиму, а не по факту.
        let hasArchives = !walkFinished || totalArchives > 0
        let hasContent = searchesContent && (!walkFinished || totalReadableFiles > 0)

        var walkWeight = searchesContent ? 0.2 : 0.5
        var archiveWeight = searchesContent ? 0.1 : 0.5
        var contentWeight = searchesContent ? 0.7 : 0.0

        // Доля фазы без работы переходит предыдущей: иначе поиск в папке без
        // архивов замирал бы на 20 %, а без читаемых файлов — на 30 %.
        if !hasContent { archiveWeight += contentWeight; contentWeight = 0 }
        if !hasArchives { walkWeight += archiveWeight; archiveWeight = 0 }

        let walkPart: Double
        if walkFinished {
            walkPart = walkWeight
        } else {
            let total = Double(scannedDirectories + queuedDirectories)
            let done = total > 0 ? Double(scannedDirectories) / total : 0
            // Потолок 0,98 доли фазы: пустая очередь на последней порции даёт
            // ровно единицу, и полоса вставала бы на границе фазы лишним
            // кадром — а работа следующих к этому моменту ещё не сосчитана, и
            // вдруг её нет вовсе. Тогда следующий же кадр прыгнул бы к концу.
            walkPart = min(done, 0.98) * walkWeight
        }

        let archivePart = totalArchives > 0
            ? Double(scannedArchives) / Double(totalArchives) * archiveWeight
            : 0
        let contentPart = totalReadableFiles > 0
            ? Double(readFiles) / Double(totalReadableFiles) * contentWeight
            : 0

        return min(1, walkPart + archivePart + contentPart)
    }
}

/// Событие поиска. Результаты идут порциями, а не одним ответом: обычные файлы
/// находятся за миллисекунды, и ждать самый медленный архив ради первой строки
/// пользователю незачем.
public enum SearchEvent: Sendable {
    case results([SearchResult])
    /// Фрагмент для уже показанной находки — та нашлась и по имени, и по
    /// содержимому. Отдельное событие, а не вторая строка в `results`: две
    /// строки на один файл читались бы как две находки.
    case snippet(url: URL, snippet: ContentSnippet)
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
    private let extractor: any TextExtracting
    private let unpacker: any ArchiveUnpacking
    private let limits: SearchLimits
    private let contentLimits: ContentSearchLimits
    private let isNetworkVolume: @Sendable (URL) -> Bool
    private let cache = ListingCache()

    public init(
        listing: any ArchiveListing = SystemArchiveListing(),
        extractor: any TextExtracting = SystemTextExtractor(),
        unpacker: any ArchiveUnpacking = SystemArchiveUnpacker(),
        limits: SearchLimits = SearchLimits(),
        contentLimits: ContentSearchLimits = ContentSearchLimits(),
        isNetworkVolume: @escaping @Sendable (URL) -> Bool = volumeIsNetwork
    ) {
        self.listing = listing
        self.extractor = extractor
        self.unpacker = unpacker
        self.limits = limits
        self.contentLimits = contentLimits
        self.isNetworkVolume = isNetworkVolume
    }

    /// Запускает поиск. Поток завершается сам по исчерпании работы или отмене.
    public func search(
        query: String,
        in directory: URL,
        searchesContent: Bool = false,
        ignoringSizeLimit: Bool = false
    ) -> AsyncStream<SearchEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.run(
                    query: query, directory: directory, searchesContent: searchesContent,
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
        searchesContent: Bool,
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
        // Тип тома выясняется один раз: запрос к ресурсам URL на сетевом диске
        // сам по себе идёт к серверу.
        let onNetwork = isNetworkVolume(directory)
        let sizeLimit = ignoringSizeLimit
            ? Int64.max
            : (onNetwork ? limits.networkArchiveBytes : limits.localArchiveBytes)
        let contentSizeLimit = ignoringSizeLimit
            ? Int64.max
            : (onNetwork ? contentLimits.networkFileBytes : contentLimits.localFileBytes)
        let archiveContentLimit = ignoringSizeLimit
            ? Int64.max
            : (onNetwork ? contentLimits.networkArchiveBytes : contentLimits.localArchiveBytes)

        // Первый проход: имена с диска. Сопоставление идёт **по ходу обхода**, а
        // не после него: обход сетевой папки с тысячами каталогов занимает
        // секунды, и результат, собранный целиком, показался бы одним рывком в
        // конце — ровно то, что выглядит как зависание.
        var archives: [URL] = []
        var readable: [URL] = []
        var matchedByName: Set<URL> = []
        var progress = SearchProgress()
        progress.searchesContent = searchesContent
        DirectoryWalk.walk(root: directory, isCancelled: { Task.isCancelled }) { batch in
            archives.append(contentsOf: batch.archives)
            if searchesContent { readable.append(contentsOf: batch.readable) }
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
            // Найденные по имени запоминаются: третья фаза допишет им фрагмент
            // вместо того, чтобы выдать вторую строку на тот же файл.
            if searchesContent { matches.forEach { matchedByName.insert($0.url) } }
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

        // Третья фаза: содержимое. Последняя намеренно — она самая дорогая, а
        // имена находятся за миллисекунды. Пользователь видит первые результаты
        // сразу и может остановиться, не дожидаясь конца.
        if searchesContent, !Task.isCancelled {
            await readContents(
                query: trimmed, files: readable, matchedByName: matchedByName,
                sizeLimit: contentSizeLimit, progress: &progress, report: &report,
                continuation: continuation
            )
        }

        // Содержимое внутри архивов — после файлов на диске: распаковка дороже
        // чтения, а находки на диске нужнее и появляются раньше.
        if searchesContent, !Task.isCancelled, !openable.isEmpty {
            await readArchiveContents(
                query: trimmed, archives: openable, sizeLimit: archiveContentLimit,
                progress: &progress, report: &report, continuation: continuation
            )
        }

        continuation.yield(.finished(report))
    }

    // MARK: - Третья фаза: содержимое

    /// Читает содержимое отобранных файлов и отдаёт совпадения.
    ///
    /// Пропущенные по размеру собираются до запуска задач, чтобы не платить за
    /// них ни одной операцией ввода-вывода, — тем же приёмом, что архивы.
    private func readContents(
        query: String,
        files: [URL],
        matchedByName: Set<URL>,
        sizeLimit: Int64,
        progress: inout SearchProgress,
        report: inout SearchReport,
        continuation: AsyncStream<SearchEvent>.Continuation
    ) async {
        var openable: [URL] = []
        for file in files {
            let size = Self.fileSize(file)
            if size > sizeLimit {
                report.skippedFiles.append(SkippedFile(url: file, sizeBytes: size))
            } else {
                openable.append(file)
            }
        }
        progress.totalReadableFiles = openable.count
        continuation.yield(.progress(progress))
        guard !openable.isEmpty else { return }

        /// Что дало чтение файла: находка, фрагмент к показанной строке или
        /// ничего. Отказ отделён от «не совпало»: первый идёт в отчёт, второе —
        /// обычный исход.
        enum Outcome: Sendable {
            case none
            case failed(URL)
            case found(SearchResult)
            case snippet(URL, ContentSnippet)
        }

        let extractor = self.extractor
        var scanned = 0

        let outcomes = await withTaskGroup(of: Outcome.self) { group in
            var index = 0

            func addTask(_ file: URL) {
                let alreadyShown = matchedByName.contains(file)
                group.addTask {
                    let text: String?
                    do {
                        text = try await extractor.text(of: file)
                    } catch {
                        // Отмена не отказ: снятый поиск не должен превращать
                        // каждый недочитанный файл в строку отчёта.
                        return error is CancellationError ? .none : .failed(file)
                    }
                    guard let text, let snippet = ContentMatcher.match(query: query, in: text) else {
                        return .none
                    }
                    if alreadyShown { return .snippet(file, snippet) }
                    return .found(SearchResult(
                        url: file, name: file.lastPathComponent, source: .file,
                        // Балл ниже порога совпадения по имени: находка по
                        // содержимому слабее — имя человек видит, а текст внутри
                        // нет. Пересортировки это не ломает, порядок внутри
                        // порции ставит rank.
                        score: 0, matchedIndices: [], snippet: snippet
                    ))
                }
            }

            // Окно задач фиксированной ширины — как у архивов: запускать сразу
            // тысячу чтений значит открыть тысячу дескрипторов и соединений разом.
            while index < openable.count, index < contentLimits.concurrentReads {
                addTask(openable[index])
                index += 1
            }

            var collected: [Outcome] = []
            while let outcome = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                collected.append(outcome)
                scanned += 1
                progress.readFiles = scanned
                switch outcome {
                case .found(let result): continuation.yield(.results([result]))
                case .snippet(let url, let snippet): continuation.yield(.snippet(url: url, snippet: snippet))
                case .failed, .none: break
                }
                continuation.yield(.progress(progress))
                if index < openable.count {
                    addTask(openable[index])
                    index += 1
                }
            }
            return collected
        }

        report.failed += outcomes.compactMap { if case .failed(let url) = $0 { url } else { nil } }
    }

    /// Читает содержимое файлов внутри архивов.
    ///
    /// Архив распаковывается **целиком один раз**, а не по записи через
    /// `ArchiveService.extractEntry`: тот запускает `bsdtar` заново на каждую
    /// запись, и архив со ста документами стоил бы ста запусков процесса и ста
    /// чтений архива — по сети ста скачиваний. Отсюда и порог, считаемый от
    /// размера архива: распакованное занимает место на диске, ограничивать надо
    /// то, что реально тратится.
    private func readArchiveContents(
        query: String,
        archives: [URL],
        sizeLimit: Int64,
        progress: inout SearchProgress,
        report: inout SearchReport,
        continuation: AsyncStream<SearchEvent>.Continuation
    ) async {
        var unpackable: [URL] = []
        for archive in archives {
            let size = Self.fileSize(archive)
            // Уже пропущенный по порогу оглавления сюда не дошёл бы: `archives`
            // — это те, что прошли первый отбор.
            if size > sizeLimit {
                report.skipped.append(SkippedArchive(url: archive, sizeBytes: size))
            } else {
                unpackable.append(archive)
            }
        }
        guard !unpackable.isEmpty else { return }

        progress.totalReadableFiles += unpackable.count
        continuation.yield(.progress(progress))

        let extractor = self.extractor
        let unpacker = self.unpacker
        var scanned = progress.readFiles

        let outcomes = await withTaskGroup(of: (URL, [SearchResult]?).self) { group in
            var index = 0

            func addTask(_ archive: URL) {
                group.addTask {
                    do {
                        let matches = try await Self.matchesInside(
                            archive, query: query, unpacker: unpacker, extractor: extractor)
                        return (archive, matches)
                    } catch is CancellationError {
                        // Отмена не отказ: снятый поиск не должен превращать
                        // каждый недораспакованный архив в строку отчёта.
                        return (archive, [])
                    } catch {
                        return (archive, nil)
                    }
                }
            }

            // Окно уже архивного: распаковка тяжелее чтения оглавления и пишет
            // на диск, а восемь параллельных распаковок крупных архивов заняли
            // бы место кратно объёму каждой.
            let window = max(1, limits.concurrentArchives / 2)
            while index < unpackable.count, index < window {
                addTask(unpackable[index])
                index += 1
            }

            var collected: [(URL, [SearchResult]?)] = []
            while let outcome = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                collected.append(outcome)
                scanned += 1
                progress.readFiles = scanned
                if let matches = outcome.1, !matches.isEmpty {
                    continuation.yield(.results(Self.rank(matches)))
                }
                continuation.yield(.progress(progress))
                if index < unpackable.count {
                    addTask(unpackable[index])
                    index += 1
                }
            }
            return collected
        }

        report.failed += outcomes.compactMap { $0.1 == nil ? $0.0 : nil }
    }

    /// Распаковывает архив во временную папку и ищет запрос в содержимом.
    ///
    /// Папка удаляется через `defer`, а не в конце функции: он срабатывает и на
    /// броске, и на отмене — брошенный поиск иначе оставлял бы распакованные
    /// гигабайты до перезапуска системы.
    private static func matchesInside(
        _ archive: URL,
        query: String,
        unpacker: any ArchiveUnpacking,
        extractor: any TextExtracting
    ) async throws -> [SearchResult] {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Проводник-поиск-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try await unpacker.unpack(archive, to: temp)

        // В распакованном читается только содержимое: имена записей уже
        // просмотрены второй фазой по оглавлению, и повторный проход дал бы
        // дубли. Вложенные архивы не вскрываются — рекурсия без внятного дна.
        let unpacked = DirectoryWalk.collect(root: temp, isCancelled: { Task.isCancelled })

        var matches: [SearchResult] = []
        for file in unpacked.readable {
            try Task.checkCancellation()
            guard let text = try? await extractor.text(of: file),
                  let snippet = ContentMatcher.match(query: query, in: text)
            else { continue }

            // Путь записи — относительно корня распаковки: по нему находка
            // извлекается заново при открытии, а временной папки к тому времени
            // уже не будет.
            let path = String(file.path.dropFirst(temp.path.count + 1))
            matches.append(SearchResult(
                url: archive, name: file.lastPathComponent, source: .archiveEntry(path: path),
                score: 0, matchedIndices: [], snippet: snippet
            ))
        }
        return matches
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
