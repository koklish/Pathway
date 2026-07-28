import Foundation
import Synchronization
import Testing

@testable import PathwayCore

@Suite("Поиск по содержимому")
struct ContentSearchTests {

    /// Читатель текста с заготовленными ответами вместо чтения диска.
    ///
    /// Считает обращения: без счётчика нечем проверить, что при выключенном
    /// режиме содержимое **не** читалось, — а это главное свойство опции.
    private final class StubExtractor: TextExtracting, @unchecked Sendable {
        private let contents: [String: String]
        private let failures: Set<String>
        /// Mutex, а не NSLock: lock() недоступен из async-контекста, а вызов
        /// приходит именно оттуда. Тот же приём, что в StubListing.
        private let requested = Mutex<[String]>([])

        init(contents: [String: String] = [:], failures: Set<String> = []) {
            self.contents = contents
            self.failures = failures
        }

        func text(of url: URL) async throws -> String? {
            let name = url.lastPathComponent
            requested.withLock { $0.append(name) }
            if failures.contains(name) { throw TextExtractionError.unreadableContainer("не прочитан") }
            return contents[name]
        }

        var requestedNames: [String] { requested.withLock { $0 } }
    }

    /// Перечислитель архивов с заготовленными ответами. Свой, а не общий с
    /// SearchEngineTests: там он приватный, а выносить хелпер в третий файл ради
    /// двух сьютов дороже, чем два коротких двойника.
    private final class StubListing: ArchiveListing, @unchecked Sendable {
        private let responses: [String: [String]]

        init(responses: [String: [String]] = [:]) {
            self.responses = responses
        }

        func entryNames(of archive: URL, limit: Int) async throws -> [String] {
            Array((responses[archive.lastPathComponent] ?? []).prefix(limit))
        }
    }

    private func makeFile(_ name: String, bytes: Int = 16, in dir: URL) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: url)
    }

    private func collect(
        _ engine: SearchEngine, query: String, in dir: URL,
        searchesContent: Bool = true, ignoringSizeLimit: Bool = false
    ) async -> (results: [SearchResult], report: SearchReport, progress: SearchProgress) {
        var results: [SearchResult] = []
        var report = SearchReport()
        var progress = SearchProgress()
        for await event in engine.search(
            query: query, in: dir, searchesContent: searchesContent, ignoringSizeLimit: ignoringSizeLimit
        ) {
            switch event {
            case .results(let batch): results += batch
            case .snippet(let url, let snippet):
                // Так же, как это делает SearchModel: обновление на месте, а не
                // добавление строки. Без этого тест на слияние дублей проверял
                // бы не то поведение, которое видит пользователь.
                if let index = results.firstIndex(where: { $0.url == url && !$0.isInsideArchive }) {
                    results[index].snippet = snippet
                }
            case .progress(let current): progress = current
            case .finished(let final): report = final
            }
        }
        return (results, report, progress)
    }

    // MARK: - Включение и выключение

    @Test("при выключенном режиме содержимое не читается ни разу")
    func doesNotReadContentWhenDisabled() async throws {
        try await withTempDirAsync { dir in
            try makeFile("заметка.txt", in: dir)
            let extractor = StubExtractor(contents: ["заметка.txt": "Поставщик ООО Ромашка"])
            let engine = SearchEngine(extractor: extractor)

            let (results, _, _) = await collect(engine, query: "ромашка", in: dir, searchesContent: false)

            // Именно невызов: иначе выключенный режим стоил бы того же, что
            // включённый, и вся опциональность была бы мнимой.
            #expect(extractor.requestedNames.isEmpty)
            #expect(results.isEmpty)
        }
    }

    @Test("находит файл по содержимому, а не по имени")
    func findsByContent() async throws {
        try await withTempDirAsync { dir in
            try makeFile("акт-17.txt", in: dir)
            let extractor = StubExtractor(contents: ["акт-17.txt": "Поставщик ООО Ромашка обязуется"])
            let engine = SearchEngine(extractor: extractor)

            let (results, _, _) = await collect(engine, query: "ромашка", in: dir)

            let found = try #require(results.first { $0.name == "акт-17.txt" })
            #expect(found.snippet?.text.contains("Ромашка") == true)
            // Имя запроса не содержит: находка обязана быть именно по содержимому.
            #expect(!found.name.localizedCaseInsensitiveContains("ромашка"))
        }
    }

    @Test("файл, совпавший и по имени, и по содержимому, даёт одну находку с фрагментом")
    func mergesNameAndContentMatch() async throws {
        try await withTempDirAsync { dir in
            try makeFile("ромашка.txt", in: dir)
            let extractor = StubExtractor(contents: ["ромашка.txt": "внутри тоже ромашка"])
            let engine = SearchEngine(extractor: extractor)

            let (results, _, _) = await collect(engine, query: "ромашка", in: dir)

            let matches = results.filter { $0.name == "ромашка.txt" }
            #expect(matches.count == 1)
            // Фрагмент дописан к находке по имени: подсветка имени сохранена.
            #expect(matches.first?.snippet != nil)
            #expect(matches.first?.matchedIndices.isEmpty == false)
        }
    }

    @Test("файл без совпадения в содержимом в выдачу не попадает")
    func missingContentIsNotReported() async throws {
        try await withTempDirAsync { dir in
            try makeFile("прочее.txt", in: dir)
            let extractor = StubExtractor(contents: ["прочее.txt": "совсем другой текст"])
            let engine = SearchEngine(extractor: extractor)

            let (results, _, _) = await collect(engine, query: "ромашка", in: dir)
            #expect(results.isEmpty)
        }
    }

    @Test("нечитаемые расширения не читаются: кандидаты отбираются по расширению")
    func skipsUnreadableExtensions() async throws {
        try await withTempDirAsync { dir in
            try makeFile("фото.jpg", in: dir)
            let extractor = StubExtractor(contents: ["фото.jpg": "ромашка"])
            let engine = SearchEngine(extractor: extractor)

            let (results, _, _) = await collect(engine, query: "ромашка", in: dir)

            #expect(extractor.requestedNames.isEmpty)
            #expect(results.isEmpty)
        }
    }

    // MARK: - Пороги

    @Test("файл больше порога не читается, а попадает в отчёт")
    func skipsOversizedFile() async throws {
        try await withTempDirAsync { dir in
            try makeFile("большой.log", bytes: 4096, in: dir)
            let extractor = StubExtractor(contents: ["большой.log": "ромашка"])
            let engine = SearchEngine(
                extractor: extractor,
                contentLimits: ContentSearchLimits(localFileBytes: 1024))

            let (results, report, _) = await collect(engine, query: "ромашка", in: dir)

            #expect(extractor.requestedNames.isEmpty)
            #expect(results.isEmpty)
            #expect(report.skippedFiles.count == 1)
            #expect(report.skippedFiles.first?.url.lastPathComponent == "большой.log")
        }
    }

    @Test("порог по сети строже локального")
    func fileThresholdDependsOnVolume() async throws {
        try await withTempDirAsync { dir in
            try makeFile("средний.txt", bytes: 4096, in: dir)
            let limits = ContentSearchLimits(localFileBytes: 8192, networkFileBytes: 1024)

            let local = SearchEngine(
                extractor: StubExtractor(contents: ["средний.txt": "ромашка"]), contentLimits: limits)
            let (localResults, _, _) = await collect(local, query: "ромашка", in: dir)
            #expect(!localResults.isEmpty)

            let network = SearchEngine(
                extractor: StubExtractor(contents: ["средний.txt": "ромашка"]),
                contentLimits: limits, isNetworkVolume: { _ in true })
            let (networkResults, report, _) = await collect(network, query: "ромашка", in: dir)
            #expect(networkResults.isEmpty)
            #expect(report.skippedFiles.count == 1)
        }
    }

    @Test("ignoringSizeLimit снимает порог и по файлам тоже")
    func forceReadsSkippedFile() async throws {
        try await withTempDirAsync { dir in
            try makeFile("большой.log", bytes: 4096, in: dir)
            let extractor = StubExtractor(contents: ["большой.log": "Поставщик ООО Ромашка"])
            let engine = SearchEngine(
                extractor: extractor,
                contentLimits: ContentSearchLimits(localFileBytes: 1024))

            let (results, report, _) = await collect(
                engine, query: "ромашка", in: dir, ignoringSizeLimit: true)

            #expect(results.count == 1)
            #expect(report.skippedFiles.isEmpty)
        }
    }

    // MARK: - Устойчивость

    @Test("ошибка чтения одного файла не отменяет поиск")
    func readFailureDoesNotStopSearch() async throws {
        try await withTempDirAsync { dir in
            try makeFile("битый.docx", in: dir)
            try makeFile("хороший.txt", in: dir)
            let extractor = StubExtractor(
                contents: ["хороший.txt": "Поставщик ООО Ромашка"], failures: ["битый.docx"])
            let engine = SearchEngine(extractor: extractor)

            let (results, report, _) = await collect(engine, query: "ромашка", in: dir)

            #expect(results.contains { $0.name == "хороший.txt" })
            #expect(report.failed.contains { $0.lastPathComponent == "битый.docx" })
        }
    }

    // MARK: - Архивы

    /// Распаковщик, раскладывающий заготовленные файлы вместо запуска bsdtar.
    private final class StubUnpacker: ArchiveUnpacking, @unchecked Sendable {
        /// Имя архива → записи внутри него (путь и содержимое).
        private let contents: [String: [String: String]]
        private let failures: Set<String>
        private let requested = Mutex<[String]>([])

        init(contents: [String: [String: String]] = [:], failures: Set<String> = []) {
            self.contents = contents
            self.failures = failures
        }

        func unpack(_ archive: URL, to directory: URL) async throws {
            let name = archive.lastPathComponent
            requested.withLock { $0.append(name) }
            if failures.contains(name) { throw ArchiveListingError.toolFailed("битый архив") }
            for (path, text) in contents[name] ?? [:] {
                let url = directory.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
        }

        var requestedNames: [String] { requested.withLock { $0 } }
    }

    @Test("находит слово в файле внутри архива")
    func findsContentInsideArchive() async throws {
        try await withTempDirAsync { dir in
            let url = dir.appendingPathComponent("Заказы.zip")
            try Data(repeating: 0, count: 512).write(to: url)

            let engine = SearchEngine(
                listing: StubListing(responses: ["Заказы.zip": ["акт.txt"]]),
                extractor: SystemTextExtractor(),
                unpacker: StubUnpacker(contents: ["Заказы.zip": ["акт.txt": "Поставщик ООО Ромашка"]]))

            let (results, _, _) = await collect(engine, query: "ромашка", in: dir)

            let found = try #require(results.first { $0.name == "акт.txt" })
            #expect(found.isInsideArchive)
            #expect(found.snippet?.text.contains("Ромашка") == true)
            // Путь записи сохранён: без него находку нечем извлечь по двойному
            // клику.
            if case .archiveEntry(let path) = found.source {
                #expect(path == "акт.txt")
            } else {
                Issue.record("находка внутри архива обязана нести путь записи")
            }
        }
    }

    @Test("при выключенном режиме архивы ради содержимого не распаковываются")
    func doesNotUnpackWhenDisabled() async throws {
        try await withTempDirAsync { dir in
            let url = dir.appendingPathComponent("Заказы.zip")
            try Data(repeating: 0, count: 512).write(to: url)

            let unpacker = StubUnpacker(contents: ["Заказы.zip": ["акт.txt": "ромашка"]])
            let engine = SearchEngine(
                listing: StubListing(responses: ["Заказы.zip": ["акт.txt"]]), unpacker: unpacker)

            _ = await collect(engine, query: "ромашка", in: dir, searchesContent: false)
            #expect(unpacker.requestedNames.isEmpty)
        }
    }

    @Test("архив больше порога распаковки не вскрывается, а попадает в отчёт")
    func skipsOversizedArchiveForContent() async throws {
        try await withTempDirAsync { dir in
            let url = dir.appendingPathComponent("Большой.zip")
            try Data(repeating: 0, count: 4096).write(to: url)

            let unpacker = StubUnpacker(contents: ["Большой.zip": ["акт.txt": "ромашка"]])
            let engine = SearchEngine(
                listing: StubListing(responses: ["Большой.zip": ["акт.txt"]]),
                unpacker: unpacker,
                contentLimits: ContentSearchLimits(localArchiveBytes: 1024))

            let (results, report, _) = await collect(engine, query: "ромашка", in: dir)

            #expect(unpacker.requestedNames.isEmpty)
            #expect(results.isEmpty)
            #expect(report.skipped.contains { $0.url.lastPathComponent == "Большой.zip" })
        }
    }

    @Test("вложенные архивы не распаковываются: рекурсия без внятного дна")
    func doesNotRecurseIntoNestedArchives() async throws {
        try await withTempDirAsync { dir in
            let url = dir.appendingPathComponent("Внешний.zip")
            try Data(repeating: 0, count: 512).write(to: url)

            let unpacker = StubUnpacker(contents: ["Внешний.zip": ["Вложенный.zip": "ромашка"]])
            let engine = SearchEngine(
                listing: StubListing(responses: ["Внешний.zip": ["Вложенный.zip"]]), unpacker: unpacker)

            _ = await collect(engine, query: "ромашка", in: dir)

            // Распакован только внешний: попытки вскрыть вложенный не было.
            #expect(unpacker.requestedNames == ["Внешний.zip"])
        }
    }

    @Test("после поиска временных папок не остаётся")
    func cleansUpTemporaryFiles() async throws {
        try await withTempDirAsync { dir in
            let url = dir.appendingPathComponent("Заказы.zip")
            try Data(repeating: 0, count: 512).write(to: url)

            let engine = SearchEngine(
                listing: StubListing(responses: ["Заказы.zip": ["акт.txt"]]),
                unpacker: StubUnpacker(contents: ["Заказы.zip": ["акт.txt": "Поставщик ООО Ромашка"]]))

            let (results, _, _) = await collect(engine, query: "ромашка", in: dir)
            #expect(!results.isEmpty)

            // Распакованное лежит вне области поиска и удаляется по завершении:
            // иначе гигабайты копились бы до перезапуска системы.
            let leftovers = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            #expect(leftovers.map(\.lastPathComponent) == ["Заказы.zip"])
        }
    }

    @Test("ошибка распаковки не отменяет поиск")
    func unpackFailureDoesNotStopSearch() async throws {
        try await withTempDirAsync { dir in
            try Data(repeating: 0, count: 512).write(to: dir.appendingPathComponent("Битый.zip"))
            try makeFile("хороший.txt", in: dir)

            let engine = SearchEngine(
                listing: StubListing(responses: ["Битый.zip": ["акт.txt"]]),
                extractor: StubExtractor(contents: ["хороший.txt": "Поставщик ООО Ромашка"]),
                unpacker: StubUnpacker(failures: ["Битый.zip"]))

            let (results, report, _) = await collect(engine, query: "ромашка", in: dir)

            #expect(results.contains { $0.name == "хороший.txt" })
            #expect(report.failed.contains { $0.lastPathComponent == "Битый.zip" })
        }
    }

    // MARK: - Ход выполнения

    @Test("счётчик прочитанных файлов растёт по ходу фазы")
    func reportsReadProgress() async throws {
        try await withTempDirAsync { dir in
            for index in 1...5 { try makeFile("файл-\(index).txt", in: dir) }
            let contents = (1...5).reduce(into: [String: String]()) {
                $0["файл-\($1).txt"] = "Поставщик ООО Ромашка"
            }
            let engine = SearchEngine(extractor: StubExtractor(contents: contents))

            let (_, _, progress) = await collect(engine, query: "ромашка", in: dir)

            #expect(progress.totalReadableFiles == 5)
            #expect(progress.readFiles == 5)
        }
    }

    @Test("доля выполненного не достигает единицы, пока идёт чтение содержимого")
    func fractionLeavesRoomForContentPhase() {
        var progress = SearchProgress(
            scannedDirectories: 1, queuedDirectories: 0, walkFinished: true, searchesContent: true)
        progress.totalReadableFiles = 10
        progress.readFiles = 0
        // Обход кончился, чтение не начиналось: полоса обязана оставить место
        // третьей фазе, иначе она замерла бы на единице до самого конца.
        #expect(progress.fraction < 0.5)

        progress.readFiles = 10
        #expect(progress.fraction == 1)
    }

    @Test("без читаемых файлов доля доходит до единицы обходом: полоса не встаёт на трети")
    func fractionCompletesWithoutReadableFiles() {
        let progress = SearchProgress(
            scannedDirectories: 1, queuedDirectories: 0, walkFinished: true, searchesContent: true)
        #expect(progress.fraction == 1)
    }
}
