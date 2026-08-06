import Foundation
import Testing

@testable import PathwayCore

@Suite("Сортировка списка файлов")
@MainActor
struct SortingTests {
    /// Каждому тесту — свой чистый UserDefaults, иначе они видят чужие записи.
    private func makeDefaults() -> UserDefaults {
        let suite = "sorting.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Файл с заданной датой создания. Дата ставится явно: создать файлы
    /// «в разное время» иначе можно только паузами, а они делают тест медленным
    /// и ненадёжным на быстрой машине.
    private func makeFile(
        _ name: String, in dir: URL, created: Date, modified: Date? = nil
    ) throws {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.creationDate: created, .modificationDate: modified ?? created],
            ofItemAtPath: url.path
        )
    }

    private func date(_ day: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
    }

    // MARK: - Порядок

    @Test("по умолчанию сортирует по дате создания, свежие сверху")
    func defaultsToCreationDateNewestFirst() throws {
        try withTempDir { dir in
            try makeFile("старый.txt", in: dir, created: date(10))
            try makeFile("свежий.txt", in: dir, created: date(30))
            try makeFile("средний.txt", in: dir, created: date(20))

            let model = BrowserModel(path: dir)
            model.reload()

            #expect(model.items.map(\.name) == ["свежий.txt", "средний.txt", "старый.txt"])
        }
    }

    @Test("при отсутствии даты создания берёт дату изменения, а не отправляет запись в конец")
    func fallsBackToModificationDate() {
        // Через FileItem напрямую: файловая система macOS дату создания ставит
        // всегда, а воспроизвести её отсутствие нужно именно для SMB.
        let withoutCreation = FileItem(
            url: URL(fileURLWithPath: "/tmp/без-создания.txt"),
            name: "без-создания.txt",
            isDirectory: false,
            modificationDate: date(20),
            creationDate: nil
        )

        #expect(withoutCreation.effectiveCreationDate == date(20))
    }

    @Test("папки остаются выше файлов при сортировке по дате")
    func directoriesStayOnTopWhenSortingByDate() throws {
        try withTempDir { dir in
            // Папка заведомо старше файла: без правила «папки сверху» она ушла бы вниз.
            let folder = dir.appendingPathComponent("папка")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.creationDate: date(1)], ofItemAtPath: folder.path)
            try makeFile("свежий.txt", in: dir, created: date(99))

            let model = BrowserModel(path: dir)
            model.reload()

            #expect(model.items.map(\.name) == ["папка", "свежий.txt"])
        }
    }

    @Test("до прихода метаданных сортирует по имени, а не по пустым датам")
    func sortsByNameUntilMetadataArrives() {
        // Записи быстрого прохода: metadataLoaded == false, дат нет ни у кого.
        let names = ["в.txt", "а.txt", "б.txt"].map { fastPassItem($0) }

        let sorted = BrowserModel.sorted(names, by: SortSettings(key: "created", ascending: false))

        // Не порядок выдачи readdir и не обратный ему: именно по имени.
        #expect(sorted.map(\.name) == ["а.txt", "б.txt", "в.txt"])
    }

    /// Запись такая, какой её отдаёт первый проход загрузки: имя есть, метаданных нет.
    private func fastPassItem(_ name: String) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            isDirectory: false,
            metadataLoaded: false
        )
    }

    @Test("после прихода метаданных пересортировывает по дате")
    func reordersOnceMetadataArrives() throws {
        try withTempDir { dir in
            try makeFile("а-старый.txt", in: dir, created: date(10))
            try makeFile("я-свежий.txt", in: dir, created: date(30))

            let model = BrowserModel(path: dir)
            model.applySort(SortSettings(key: "created", ascending: false))
            model.reload()

            // Алфавит поставил бы «а-старый» первым — значит порядок задан датой.
            #expect(model.items.map(\.name) == ["я-свежий.txt", "а-старый.txt"])
        }
    }

    @Test("сортировка по имени по убыванию действует и на списке без метаданных")
    func respectsDirectionForNameWithoutMetadata() {
        let names = ["а.txt", "б.txt"].map { fastPassItem($0) }

        let sorted = BrowserModel.sorted(names, by: SortSettings(key: "name", ascending: false))

        #expect(sorted.map(\.name) == ["б.txt", "а.txt"])
    }

    // MARK: - Колонка

    @Test("колонка даты создания при отсутствии даты показывает дату изменения, а не прочерк")
    func creationColumnFallsBackInsteadOfDash() {
        let model = BrowserModel(path: URL(fileURLWithPath: "/tmp"))
        let item = FileItem(
            url: URL(fileURLWithPath: "/tmp/файл.txt"),
            name: "файл.txt",
            isDirectory: false,
            modificationDate: date(20),
            creationDate: nil
        )

        #expect(model.text(for: item, column: "created") != "—")
    }

    @Test("колонка даты создания без обеих дат показывает прочерк")
    func creationColumnShowsDashWithoutAnyDate() {
        let model = BrowserModel(path: URL(fileURLWithPath: "/tmp"))
        let item = FileItem(
            url: URL(fileURLWithPath: "/tmp/файл.txt"),
            name: "файл.txt",
            isDirectory: false,
            metadataLoaded: false
        )

        #expect(model.text(for: item, column: "created") == "—")
    }

    // MARK: - Общая настройка

    @Test("смена сортировки в одной вкладке меняет её во всех")
    func sortAppliesToEveryTab() {
        let model = TabsModel(path: home, store: TabsStore(defaults: makeDefaults()))
        model.open(URL(fileURLWithPath: "/tmp"), activate: false)

        model.sort = SortSettings(key: "size", ascending: true)

        #expect(model.tabs.allSatisfy { $0.browser.sortKey == "size" })
        #expect(model.tabs.allSatisfy { $0.browser.sortAscending })
    }

    @Test("новая вкладка открывается с текущей сортировкой, а не с сортировкой по умолчанию")
    func newTabInheritsCurrentSort() {
        let model = TabsModel(path: home, store: TabsStore(defaults: makeDefaults()))
        model.sort = SortSettings(key: "kind", ascending: false)

        model.open(URL(fileURLWithPath: "/tmp"), activate: false)

        #expect(model.tabs.last?.browser.sortKey == "kind")
        #expect(model.tabs.last?.browser.sortAscending == false)
    }

    @Test("восстановленные вкладки получают сохранённую сортировку")
    func restoredTabsGetSavedSort() {
        let defaults = makeDefaults()
        let store = TabsStore(defaults: defaults)
        store.save(sort: SortSettings(key: "size", ascending: true))

        let model = TabsModel(path: home, store: store)

        #expect(model.tabs.allSatisfy { $0.browser.sortKey == "size" })
    }

    // MARK: - Хранение

    @Test("сохранённая сортировка переживает перезапуск")
    func sortSurvivesRestart() {
        let defaults = makeDefaults()
        TabsStore(defaults: defaults).save(sort: SortSettings(key: "kind", ascending: true))

        let restored = TabsStore(defaults: defaults).restoreSort()

        #expect(restored == SortSettings(key: "kind", ascending: true))
    }

    @Test("без сохранённого значения умолчание — дата создания по убыванию")
    func defaultSortIsCreationDescending() {
        let restored = TabsStore(defaults: makeDefaults()).restoreSort()

        #expect(restored.key == "created")
        #expect(restored.ascending == false)
    }

    @Test("явно сохранённое «по возрастанию» отличимо от отсутствующего ключа")
    func explicitAscendingIsDistinguishableFromMissingKey() {
        let defaults = makeDefaults()
        // Направление по возрастанию совпадает с тем, что UserDefaults.bool
        // возвращает для отсутствующего ключа, — потому его и стережём.
        TabsStore(defaults: defaults).save(sort: SortSettings(key: "created", ascending: true))

        #expect(TabsStore(defaults: defaults).restoreSort().ascending)
    }

    @Test("смена сортировки сохраняется сразу, без закрытия приложения")
    func sortIsPersistedOnChange() {
        let defaults = makeDefaults()
        let model = TabsModel(path: home, store: TabsStore(defaults: defaults))

        model.sort = SortSettings(key: "modified", ascending: true)

        #expect(TabsStore(defaults: defaults).restoreSort() == SortSettings(key: "modified", ascending: true))
    }

    // MARK: - Загрузка

    @Test("быстрый проход оставляет дату создания пустой, а не подставляет текущее время")
    func fastPassLeavesCreationDateEmpty() throws {
        try withTempDir { dir in
            try makeFile("файл.txt", in: dir, created: date(10))

            let names = try DirectoryLoader().loadNames(directory: dir)

            #expect(names.first?.creationDate == nil)
            #expect(names.first?.metadataLoaded == false)
        }
    }

    @Test("второй проход заполняет дату создания")
    func metadataPassFillsCreationDate() throws {
        try withTempDir { dir in
            try makeFile("файл.txt", in: dir, created: date(10))
            let loader = DirectoryLoader()

            let detailed = loader.loadMetadata(for: try loader.loadNames(directory: dir))

            #expect(detailed.first?.creationDate == date(10))
        }
    }
}
