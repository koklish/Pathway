import Foundation
import Testing

@testable import PathwayCore

@Suite("Состояние поиска")
@MainActor
struct SearchModelTests {

    private final class StubListing: ArchiveListing, @unchecked Sendable {
        let responses: [String: [String]]
        init(_ responses: [String: [String]] = [:]) { self.responses = responses }

        func entryNames(of archive: URL, limit: Int) async throws -> [String] {
            responses[archive.lastPathComponent] ?? []
        }
    }

    private func makeModel(_ listing: StubListing = StubListing()) -> SearchModel {
        SearchModel(engine: SearchEngine(listing: listing))
    }

    /// Ждёт завершения поиска: модель асинхронна, а тест синхронен.
    private func waitUntilDone(_ model: SearchModel) async {
        for _ in 0..<200 where model.isSearching {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("до первого поиска модель не активна")
    func startsInactive() {
        let model = makeModel()

        #expect(!model.isActive)
        #expect(model.results.isEmpty)
    }

    @Test("находит файлы и запоминает запрос")
    func findsFiles() async throws {
        try await withTempDirAsync { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("договор.txt"))
            let model = makeModel()
            model.query = "договор"

            model.search(in: dir)
            await waitUntilDone(model)

            #expect(model.isActive)
            #expect(model.activeQuery == "договор")
            #expect(model.results.contains { $0.name == "договор.txt" })
        }
    }

    @Test("пустой запрос поиск не запускает")
    func ignoresEmptyQuery() async throws {
        try await withTempDirAsync { dir in
            let model = makeModel()
            model.query = "   "

            model.search(in: dir)

            #expect(!model.isActive)
            #expect(!model.isSearching)
        }
    }

    @Test("новый поиск очищает выдачу прошлого, а не дополняет её")
    func replacesPreviousResults() async throws {
        try await withTempDirAsync { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("договор.txt"))
            try Data("x".utf8).write(to: dir.appendingPathComponent("акт.txt"))
            let model = makeModel()

            model.query = "договор"
            model.search(in: dir)
            await waitUntilDone(model)

            model.query = "акт"
            model.search(in: dir)
            await waitUntilDone(model)

            #expect(model.results.allSatisfy { $0.name != "договор.txt" })
        }
    }

    @Test("отмена закрывает поиск и очищает запрос")
    func cancelClearsState() async throws {
        try await withTempDirAsync { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("договор.txt"))
            let model = makeModel()
            model.query = "договор"
            model.search(in: dir)
            await waitUntilDone(model)

            model.cancel()

            #expect(!model.isActive)
            #expect(model.results.isEmpty)
            #expect(model.query.isEmpty)
        }
    }

    @Test("порции дописываются в конец, а не пересортировывают показанное")
    func batchesAppendWithoutReordering() async throws {
        // Файлы находятся сразу, записи архива — позже. Запись архива имеет
        // балл выше (точное совпадение против частичного), но обязана встать
        // ниже: пересортировка двигала бы строки под курсором, и кликнуть по
        // находке, не дождавшись конца поиска, было бы нельзя.
        try await withTempDirAsync { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("акт-договор.txt"))
            try Data(repeating: 0, count: 512).write(to: dir.appendingPathComponent("Архив.zip"))
            let model = makeModel(StubListing(["Архив.zip": ["договор.pdf"]]))
            model.query = "договор"

            model.search(in: dir)
            await waitUntilDone(model)

            let names = model.results.map(\.name)
            #expect(names == ["акт-договор.txt", "договор.pdf"])
            // Балл более поздней находки выше — значит порядок именно по
            // приходу, а не случайно совпал с сортировкой.
            let scores = model.results.map(\.score)
            #expect(scores.last! > scores.first!)
        }
    }

    @Test("счётчик просмотренного доходит до модели")
    func tracksProgress() async throws {
        try await withTempDirAsync { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("договор.txt"))
            try Data("x".utf8).write(to: dir.appendingPathComponent("прочее.txt"))
            let model = makeModel(StubListing())
            model.query = "договор"

            model.search(in: dir)
            await waitUntilDone(model)

            // Просмотрены оба файла, найден один: счётчик считает обойдённое,
            // а не совпавшее.
            #expect(model.progress.scannedFiles == 2)
            #expect(model.results.count == 1)
        }
    }

    @Test("доля выполненного доходит до единицы")
    func fractionReachesOne() async throws {
        try await withTempDirAsync { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("договор.txt"))
            let model = makeModel(StubListing())
            model.query = "договор"

            model.search(in: dir)
            await waitUntilDone(model)

            #expect(model.fraction == 1)
        }
    }

    @Test("доля не убывает, даже когда оценка движка падает")
    func fractionNeverGoesBackwards() async throws {
        try await withTempDirAsync { dir in
            // Ветка глубже соседей: дойдя до неё, обход дописывает в очередь
            // новые папки, и честная оценка проседает.
            try Data("x".utf8).write(to: dir.appendingPathComponent("мелкий.txt"))
            for i in 1...12 {
                let deep = dir.appendingPathComponent("глубоко/\(i)/ещё/дальше")
                try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
                try Data("x".utf8).write(to: deep.appendingPathComponent("файл.txt"))
            }
            let model = makeModel(StubListing())
            model.query = "файл"

            model.search(in: dir)

            // Снимки берутся по ходу поиска. Через sleep, а не Task.yield:
            // модель на главном акторе, и активное ожидание не отпускало бы
            // его — задача поиска не получила бы шанса продвинуться.
            var samples: [Double] = []
            for _ in 0..<200 where model.isSearching {
                samples.append(model.fraction)
                try? await Task.sleep(for: .milliseconds(1))
            }
            samples.append(model.fraction)

            // Полоса, едущая назад, читается как сбой — гасится в модели.
            #expect(samples == samples.sorted())
        }
    }

    @Test("новый поиск сбрасывает долю, а не продолжает с прошлой")
    func fractionResetsOnNewSearch() async throws {
        try await withTempDirAsync { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("договор.txt"))
            let model = makeModel(StubListing())
            model.query = "договор"

            model.search(in: dir)
            await waitUntilDone(model)
            #expect(model.fraction == 1)

            // Без сброса вторая полоса стартовала бы с края и стояла на месте.
            model.query = "акт"
            model.search(in: dir)
            model.cancel()

            #expect(model.fraction == 0)
        }
    }

    @Test("закрытие с сохранением оставляет запрос в поле")
    func closeKeepingQueryPreservesText() async throws {
        try await withTempDirAsync { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("договор.txt"))
            let model = makeModel(StubListing())
            model.query = "договор"

            model.search(in: dir)
            await waitUntilDone(model)

            model.closeKeepingQuery()

            // Выдача закрыта, но запрос на месте: Enter обязан вернуть её, не
            // заставляя набирать заново.
            #expect(!model.isActive)
            #expect(model.results.isEmpty)
            #expect(model.query == "договор")
        }
    }

    @Test("обычная отмена запрос стирает")
    func cancelClearsQuery() async throws {
        try await withTempDirAsync { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("договор.txt"))
            let model = makeModel(StubListing())
            model.query = "договор"

            model.search(in: dir)
            await waitUntilDone(model)

            model.cancel()

            #expect(model.query.isEmpty)
        }
    }

    @Test("путь записи архива для буфера включает имя записи, а не только архив")
    func clipboardPathNamesEntry() {
        let model = makeModel(StubListing())
        let archive = URL(fileURLWithPath: "/Папка/Заказы.zip")

        let file = SearchResult(url: URL(fileURLWithPath: "/Папка/договор.txt"),
                                name: "договор.txt", source: .file, score: 1, matchedIndices: [])
        #expect(model.pathForClipboard(file) == "/Папка/договор.txt")

        let entry = SearchResult(url: archive, name: "договор.pdf",
                                 source: .archiveEntry(path: "2024/договор.pdf"),
                                 score: 1, matchedIndices: [])
        // Голый путь архива не сказал бы, что именно нашлось.
        #expect(model.pathForClipboard(entry) == "/Папка/Заказы.zip › 2024/договор.pdf")
    }

    @Test("отмена обнуляет счётчик, а не оставляет числа прошлого поиска")
    func cancelResetsProgress() async throws {
        try await withTempDirAsync { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("договор.txt"))
            let model = makeModel(StubListing())
            model.query = "договор"

            model.search(in: dir)
            await waitUntilDone(model)
            #expect(model.progress.scannedFiles > 0)

            model.cancel()

            #expect(model.progress.scannedFiles == 0)
        }
    }

    @Test("пропущенные архивы попадают в отчёт")
    func reportsSkippedArchives() async throws {
        try await withTempDirAsync { dir in
            try Data(repeating: 0, count: 4096).write(to: dir.appendingPathComponent("Большой.zip"))
            let engine = SearchEngine(
                listing: StubListing(["Большой.zip": ["договор.pdf"]]),
                limits: SearchLimits(localArchiveBytes: 1024))
            let model = SearchModel(engine: engine)
            model.query = "договор"

            model.search(in: dir)
            await waitUntilDone(model)

            #expect(model.report.skipped.count == 1)
            #expect(!model.report.isComplete)
        }
    }

    @Test("повторный поиск с пропущенными вскрывает большой архив")
    func searchIncludingSkippedOpensBigArchive() async throws {
        try await withTempDirAsync { dir in
            try Data(repeating: 0, count: 4096).write(to: dir.appendingPathComponent("Большой.zip"))
            let engine = SearchEngine(
                listing: StubListing(["Большой.zip": ["договор.pdf"]]),
                limits: SearchLimits(localArchiveBytes: 1024))
            let model = SearchModel(engine: engine)
            model.query = "договор"
            model.search(in: dir)
            await waitUntilDone(model)

            model.searchIncludingSkipped()
            await waitUntilDone(model)

            #expect(model.results.contains { $0.name == "договор.pdf" })
        }
    }

    @Test("файл с диска открывается без извлечения")
    func opensPlainFileDirectly() async throws {
        try await withTempDirAsync { dir in
            let file = dir.appendingPathComponent("договор.txt")
            try Data("x".utf8).write(to: file)
            let model = makeModel()
            let result = SearchResult(url: file, name: "договор.txt", source: .file, score: 900)

            let opened = await model.fileToOpen(for: result)

            #expect(opened == file)
            #expect(model.errorMessage == nil)
        }
    }

    @Test("несуществующая запись архива даёт текст ошибки, а не пустой путь")
    func reportsExtractionFailure() async throws {
        try await withTempDirAsync { dir in
            let archive = dir.appendingPathComponent("Битый.zip")
            try Data("это не архив".utf8).write(to: archive)
            let model = makeModel()
            let result = SearchResult(
                url: archive, name: "нет.pdf", source: .archiveEntry(path: "нет.pdf"), score: 900)

            let opened = await model.fileToOpen(for: result)

            #expect(opened == nil)
            #expect(model.errorMessage != nil)
        }
    }

    // MARK: - Поиск по содержимому

    @Test("режим содержимого сохраняется между поисками")
    func contentModeSurvivesSearches() async throws {
        try await withTempDirAsync { dir in
            try Data("Поставщик ООО Ромашка".utf8)
                .write(to: dir.appendingPathComponent("акт.txt"))
            let model = makeModel()
            model.searchesContent = true

            model.query = "ромашка"
            model.search(in: dir)
            await waitUntilDone(model)
            #expect(model.results.count == 1)

            // Второй поиск подряд: флаг не должен сброситься сам.
            model.query = "ромашка"
            model.search(in: dir)
            await waitUntilDone(model)
            #expect(model.searchesContent)
            #expect(model.results.count == 1)
        }
    }

    @Test("закрытие поиска не сбрасывает режим содержимого")
    func cancelKeepsContentMode() async throws {
        try await withTempDirAsync { dir in
            let model = makeModel()
            model.searchesContent = true
            model.query = "договор"
            model.search(in: dir)
            await waitUntilDone(model)

            model.cancel()

            // Режим — настройка поиска, а не его состояние: сбрасывать её на
            // закрытии значило бы заставлять включать заново каждый раз.
            #expect(model.searchesContent)
        }
    }

    @Test("при выключенном режиме содержимое не ищется")
    func doesNotSearchContentWhenDisabled() async throws {
        try await withTempDirAsync { dir in
            try Data("Поставщик ООО Ромашка".utf8)
                .write(to: dir.appendingPathComponent("акт.txt"))
            let model = makeModel()

            model.query = "ромашка"
            model.search(in: dir)
            await waitUntilDone(model)

            #expect(model.results.isEmpty)
        }
    }

    @Test("фрагмент дописывается к показанной строке, а не добавляет вторую")
    func snippetUpdatesExistingRow() async throws {
        try await withTempDirAsync { dir in
            try Data("внутри тоже ромашка".utf8)
                .write(to: dir.appendingPathComponent("ромашка.txt"))
            let model = makeModel()
            model.searchesContent = true

            model.query = "ромашка"
            model.search(in: dir)
            await waitUntilDone(model)

            #expect(model.results.count == 1)
            #expect(model.results.first?.snippet != nil)
            // Подсветка имени сохранена: строка та же, дописан только фрагмент.
            #expect(model.results.first?.matchedIndices.isEmpty == false)
        }
    }

    @Test("searchIncludingSkipped снимает порог и по файлам тоже")
    func forceSearchLiftsFileThreshold() async throws {
        try await withTempDirAsync { dir in
            let text = String(repeating: "а", count: 4096) + "Ромашка"
            try Data(text.utf8).write(to: dir.appendingPathComponent("большой.log"))
            let model = SearchModel(engine: SearchEngine(
                listing: StubListing(),
                contentLimits: ContentSearchLimits(localFileBytes: 1024)))
            model.searchesContent = true

            model.query = "ромашка"
            model.search(in: dir)
            await waitUntilDone(model)
            #expect(model.results.isEmpty)
            #expect(model.report.skippedFiles.count == 1)

            model.searchIncludingSkipped()
            await waitUntilDone(model)
            #expect(model.results.count == 1)
            #expect(model.report.skippedFiles.isEmpty)
        }
    }
}
