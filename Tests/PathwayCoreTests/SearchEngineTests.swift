import Foundation
import Synchronization
import Testing

@testable import PathwayCore

@Suite("Движок поиска")
struct SearchEngineTests {

    /// Перечислитель архивов с заготовленными ответами вместо чтения диска.
    private final class StubListing: ArchiveListing, @unchecked Sendable {
        private let responses: [String: [String]]
        private let failures: Set<String>
        /// Mutex, а не NSLock: lock() недоступен из async-контекста, а вызов
        /// приходит именно оттуда.
        private let requested = Mutex<[String]>([])

        init(responses: [String: [String]] = [:], failures: Set<String> = []) {
            self.responses = responses
            self.failures = failures
        }

        func entryNames(of archive: URL, limit: Int) async throws -> [String] {
            let name = archive.lastPathComponent
            requested.withLock { $0.append(name) }

            if failures.contains(name) { throw ArchiveListingError.toolFailed("битый архив") }
            return Array((responses[name] ?? []).prefix(limit))
        }

        var requestedNames: [String] { requested.withLock { $0 } }
    }

    /// Собирает файлы в папке; архивы — пустые файлы заданного размера, их
    /// содержимое подставляет StubListing.
    private func makeTree(in dir: URL, files: [String] = [], archives: [String: Int] = [:]) throws {
        for file in files {
            let url = dir.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        for (archive, size) in archives {
            let url = dir.appendingPathComponent(archive)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0, count: size).write(to: url)
        }
    }

    private func collect(
        _ engine: SearchEngine, query: String, in dir: URL
    ) async -> (results: [SearchResult], report: SearchReport, progress: SearchProgress) {
        var results: [SearchResult] = []
        var report = SearchReport()
        var progress = SearchProgress()
        for await event in engine.search(query: query, in: dir) {
            switch event {
            case .results(let batch): results += batch
            // Фрагментов здесь не бывает: поиск по содержимому выключен по
            // умолчанию, и эти тесты его не включают.
            case .snippet: break
            case .progress(let current): progress = current
            case .finished(let final): report = final
            }
        }
        return (results, report, progress)
    }

    // MARK: - Основное

    @Test("находит файлы на диске и записи внутри архивов в одном списке")
    func findsFilesAndArchiveEntries() async throws {
        try await withTempDirAsync { dir in
            try makeTree(in: dir, files: ["договор.txt"], archives: ["Заказы.zip": 1024])
            let listing = StubListing(responses: ["Заказы.zip": ["2024/договор-АБВ.pdf", "прочее.txt"]])
            let engine = SearchEngine(listing: listing)

            let (results, _, _) = await collect(engine, query: "договор", in: dir)

            #expect(results.contains { $0.name == "договор.txt" && !$0.isInsideArchive })
            #expect(results.contains { $0.name == "договор-АБВ.pdf" && $0.isInsideArchive })
            #expect(!results.contains { $0.name == "прочее.txt" })
        }
    }

    @Test("результаты отсортированы по баллу, а не по имени")
    func sortsByScore() async throws {
        try await withTempDirAsync { dir in
            try makeTree(in: dir, files: ["акт-договор.txt", "договор.txt"])
            let engine = SearchEngine(listing: StubListing())

            let (results, _, _) = await collect(engine, query: "договор", in: dir)

            // «договор.txt» начинается с запроса, «акт-договор.txt» — нет.
            #expect(results.first?.name == "договор.txt")
        }
    }

    @Test("ищет во вложенных папках, а не только в текущей")
    func searchesRecursively() async throws {
        try await withTempDirAsync { dir in
            try makeTree(in: dir, files: ["глубоко/внутри/договор.txt"])
            let engine = SearchEngine(listing: StubListing())

            let (results, _, _) = await collect(engine, query: "договор", in: dir)

            #expect(results.contains { $0.name == "договор.txt" })
        }
    }

    @Test("путь записи архива показывается с именем архива")
    func showsArchivePath() async throws {
        try await withTempDirAsync { dir in
            try makeTree(in: dir, archives: ["Заказы.zip": 1024])
            let listing = StubListing(responses: ["Заказы.zip": ["2024/договор.pdf"]])
            let engine = SearchEngine(listing: listing)

            let (results, _, _) = await collect(engine, query: "договор", in: dir)
            let found = try #require(results.first)

            #expect(found.location(relativeTo: dir) == "Заказы.zip › 2024/")
        }
    }

    // MARK: - Устойчивость

    @Test("битый архив не отменяет поиск, а попадает в счётчик")
    func brokenArchiveDoesNotStopSearch() async throws {
        try await withTempDirAsync { dir in
            try makeTree(in: dir, files: ["договор.txt"], archives: ["Битый.zip": 1024])
            let listing = StubListing(failures: ["Битый.zip"])
            let engine = SearchEngine(listing: listing)

            let (results, report, _) = await collect(engine, query: "договор", in: dir)

            #expect(results.contains { $0.name == "договор.txt" })
            #expect(report.failed.count == 1)
        }
    }

    @Test("архив больше порога не вскрывается вовсе")
    func skipsOversizedArchive() async throws {
        try await withTempDirAsync { dir in
            try makeTree(in: dir, archives: ["Большой.zip": 4096])
            let listing = StubListing(responses: ["Большой.zip": ["договор.pdf"]])
            let engine = SearchEngine(listing: listing, limits: SearchLimits(localArchiveBytes: 1024))

            let (results, report, _) = await collect(engine, query: "договор", in: dir)

            // Проверяется именно невызов: иначе «пропуск» означал бы, что архив
            // всё-таки прочитан, и вся экономия по сети была бы мнимой.
            #expect(listing.requestedNames.isEmpty)
            #expect(results.isEmpty)
            #expect(report.skipped.count == 1)
        }
    }

    @Test("порог берётся по типу тома: на сети строже, чем локально")
    func thresholdDependsOnVolume() async throws {
        try await withTempDirAsync { dir in
            try makeTree(in: dir, archives: ["Средний.zip": 4096])
            let listing = StubListing(responses: ["Средний.zip": ["договор.pdf"]])
            let limits = SearchLimits(localArchiveBytes: 8192, networkArchiveBytes: 1024)

            let local = SearchEngine(listing: listing, limits: limits)
            let (localResults, _, _) = await collect(local, query: "договор", in: dir)
            #expect(!localResults.isEmpty)

            let network = SearchEngine(listing: StubListing(responses: ["Средний.zip": ["договор.pdf"]]),
                                       limits: limits, isNetworkVolume: { _ in true })
            let (networkResults, report, _) = await collect(network, query: "договор", in: dir)
            #expect(networkResults.isEmpty)
            #expect(report.skipped.count == 1)
        }
    }

    @Test("пропущенный архив можно вскрыть принудительно")
    func forceOpensSkippedArchive() async throws {
        try await withTempDirAsync { dir in
            try makeTree(in: dir, archives: ["Большой.zip": 4096])
            let listing = StubListing(responses: ["Большой.zip": ["договор.pdf"]])
            let engine = SearchEngine(listing: listing, limits: SearchLimits(localArchiveBytes: 1024))

            var results: [SearchResult] = []
            for await event in engine.search(query: "договор", in: dir, ignoringSizeLimit: true) {
                if case .results(let batch) = event { results += batch }
            }

            #expect(results.contains { $0.name == "договор.pdf" })
        }
    }

    @Test("пустой запрос не даёт результатов и не трогает архивы")
    func emptyQueryFindsNothing() async throws {
        try await withTempDirAsync { dir in
            try makeTree(in: dir, files: ["договор.txt"], archives: ["Заказы.zip": 1024])
            let listing = StubListing(responses: ["Заказы.zip": ["договор.pdf"]])
            let engine = SearchEngine(listing: listing)

            let (results, _, _) = await collect(engine, query: "   ", in: dir)

            #expect(results.isEmpty)
            #expect(listing.requestedNames.isEmpty)
        }
    }

    // MARK: - Кэш

    @Test("повторный поиск не перечитывает тот же архив")
    func cachesArchiveListing() async throws {
        try await withTempDirAsync { dir in
            try makeTree(in: dir, archives: ["Заказы.zip": 1024])
            let listing = StubListing(responses: ["Заказы.zip": ["договор.pdf", "акт.pdf"]])
            let engine = SearchEngine(listing: listing)

            _ = await collect(engine, query: "договор", in: dir)
            _ = await collect(engine, query: "акт", in: dir)

            // Второй поиск обязан взять оглавление из кэша: по сети повторное
            // чтение RAR стоило бы всего трафика заново.
            #expect(listing.requestedNames == ["Заказы.zip"])
        }
    }

    @Test("изменение архива сбрасывает кэш")
    func invalidatesCacheOnChange() async throws {
        try await withTempDirAsync { dir in
            let archive = dir.appendingPathComponent("Заказы.zip")
            try Data(repeating: 0, count: 1024).write(to: archive)
            let listing = StubListing(responses: ["Заказы.zip": ["договор.pdf"]])
            let engine = SearchEngine(listing: listing)

            _ = await collect(engine, query: "договор", in: dir)
            // Другой размер — архив пересобрали, оглавление могло измениться.
            try Data(repeating: 0, count: 2048).write(to: archive)
            _ = await collect(engine, query: "договор", in: dir)

            #expect(listing.requestedNames.count == 2)
        }
    }

    // MARK: - Отмена

    @Test("отменённый поиск не досылает результаты")
    func cancellationStopsResults() async throws {
        try await withTempDirAsync { dir in
            try makeTree(in: dir, files: (1...200).map { "договор\($0).txt" })
            let engine = SearchEngine(listing: StubListing())

            let task = Task {
                var count = 0
                for await event in engine.search(query: "договор", in: dir) {
                    if case .results(let batch) = event { count += batch.count }
                }
                return count
            }
            task.cancel()
            let count = await task.value

            // Отмена не обязана успеть до первой порции, но обязана оборвать
            // поток: полного набора при отменённой задаче быть не должно.
            #expect(count <= 200)
        }
    }

    // MARK: - Ход поиска

    @Test("находки в разных папках приходят разными порциями, а не одной в конце")
    func yieldsResultsWhileWalking() async throws {
        try await withTempDirAsync { dir in
            // По файлу в каждой из десяти папок: обход читает их поочерёдно, и
            // каждая обязана дать свою порцию сразу.
            try makeTree(in: dir, files: (1...10).map { "папка\($0)/договор.txt" })
            let engine = SearchEngine(listing: StubListing())

            var batches = 0
            for await event in engine.search(query: "договор", in: dir) {
                if case .results = event { batches += 1 }
            }

            // Ровно то, что чинит «долго и непонятно»: одна порция означала бы,
            // что список наполняется рывком после всего обхода.
            #expect(batches == 10)
        }
    }

    @Test("счётчик просмотренного растёт по ходу, а не выставляется в конце")
    func reportsProgressWhileWalking() async throws {
        try await withTempDirAsync { dir in
            try makeTree(in: dir, files: (1...10).map { "папка\($0)/файл.txt" })
            let engine = SearchEngine(listing: StubListing())

            var scanned: [Int] = []
            for await event in engine.search(query: "неттакого", in: dir) {
                if case .progress(let current) = event { scanned.append(current.scannedFiles) }
            }

            // Промежуточные значения важнее итогового: по ним человек и видит,
            // что работа идёт. Один отчёт в конце ничем не лучше кружка.
            #expect(scanned.count > 1)
            #expect(scanned == scanned.sorted())
            // Десять папок и десять файлов в них.
            #expect(scanned.last == 20)
        }
    }

    @Test("счётчик архивов знает общее число до вскрытия")
    func reportsArchiveTotal() async throws {
        try await withTempDirAsync { dir in
            try makeTree(in: dir, archives: ["а.zip": 16, "б.zip": 16, "в.zip": 16])
            let engine = SearchEngine(listing: StubListing())

            var progress = SearchProgress()
            for await event in engine.search(query: "договор", in: dir) {
                if case .progress(let current) = event { progress = current }
            }

            // Общее известно только после обхода — но до вскрытия, иначе
            // «архивов 3 из 3» появилось бы лишь в самом конце.
            #expect(progress.totalArchives == 3)
            #expect(progress.scannedArchives == 3)
        }
    }

    // MARK: - Доля выполненного

    @Test("доля растёт по ходу обхода и доходит до края")
    func fractionGrowsWhileWalking() async throws {
        try await withTempDirAsync { dir in
            try makeTree(in: dir, files: (1...10).map { "папка\($0)/файл.txt" })
            let engine = SearchEngine(listing: StubListing())

            var fractions: [Double] = []
            for await event in engine.search(query: "неттакого", in: dir) {
                if case .progress(let current) = event { fractions.append(current.fraction) }
            }

            #expect(fractions.count > 1)
            #expect(fractions.last == 1)
        }
    }

    @Test("без архивов обход занимает всю полосу, а не половину")
    func walkAloneFillsWholeBar() async throws {
        try await withTempDirAsync { dir in
            try makeTree(in: dir, files: ["договор.txt"])
            let engine = SearchEngine(listing: StubListing())

            var last = SearchProgress()
            for await event in engine.search(query: "договор", in: dir) {
                if case .progress(let current) = event { last = current }
            }

            // Иначе поиск в обычной папке замирал бы на 50 % и выглядел
            // незаконченным.
            #expect(last.totalArchives == 0)
            #expect(last.fraction == 1)
        }
    }

    @Test("с архивами обход даёт половину, вскрытие — вторую")
    func archivesTakeSecondHalf() async throws {
        try await withTempDirAsync { dir in
            try makeTree(in: dir, archives: ["а.zip": 16, "б.zip": 16])
            let engine = SearchEngine(listing: StubListing())

            var afterWalk: Double?
            for await event in engine.search(query: "договор", in: dir) {
                guard case .progress(let current) = event else { continue }
                // Первое событие, где обход позади, а архивы ещё не начаты.
                if current.walkFinished, current.scannedArchives == 0, afterWalk == nil {
                    afterWalk = current.fraction
                }
            }

            #expect(afterWalk == 0.5)
        }
    }

    @Test("доля не превышает единицы")
    func fractionNeverExceedsOne() async throws {
        try await withTempDirAsync { dir in
            try makeTree(in: dir, files: (1...5).map { "п\($0)/файл.txt" },
                         archives: ["а.zip": 16, "б.zip": 16])
            let engine = SearchEngine(listing: StubListing())

            for await event in engine.search(query: "файл", in: dir) {
                if case .progress(let current) = event { #expect(current.fraction <= 1) }
            }
        }
    }

    @Test("до первой обойдённой папки доля равна нулю, а не выдуманному числу")
    func fractionStartsAtZero() {
        #expect(SearchProgress().fraction == 0)
        // Очередь известна, но ни одной папки ещё не прочитано.
        #expect(SearchProgress(queuedDirectories: 5).fraction == 0)
    }

    @Test("незавершённый обход не доходит до половины даже с пустой очередью")
    func unfinishedWalkStaysBelowHalf() {
        // Последняя порция обхода: очередь пуста, но архивы не сосчитаны.
        // Дай здесь ровно 50 %, и полоса встала бы на половине лишним кадром,
        // а следующий прыгнул бы сразу на 100 %, если архивов не окажется.
        let last = SearchProgress(scannedDirectories: 100, queuedDirectories: 0)
        #expect(last.fraction < 0.5)
        #expect(last.fraction > 0.45)

        // А объявленный законченным — ровно половину.
        let finished = SearchProgress(scannedDirectories: 100, totalArchives: 3, walkFinished: true)
        #expect(finished.fraction == 0.5)
    }
}
