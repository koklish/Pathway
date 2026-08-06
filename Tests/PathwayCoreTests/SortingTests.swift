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

    /// Файл с заданной датой изменения. Дата ставится явно: развести файлы «во
    /// времени» иначе можно только паузами, а они делают тест медленным и
    /// ненадёжным на быстрой машине.
    private func makeFile(_ name: String, in dir: URL, modified: Date) throws {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func date(_ day: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
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

    // MARK: - Порядок

    @Test("по умолчанию сортирует по дате изменения, свежие сверху")
    func defaultsToModificationDateNewestFirst() throws {
        try withTempDir { dir in
            try makeFile("старый.txt", in: dir, modified: date(10))
            try makeFile("свежий.txt", in: dir, modified: date(30))
            try makeFile("средний.txt", in: dir, modified: date(20))

            let model = BrowserModel(path: dir)
            model.reload()

            #expect(model.items.map(\.name) == ["свежий.txt", "средний.txt", "старый.txt"])
        }
    }

    @Test("папки остаются выше файлов при сортировке по дате")
    func directoriesStayOnTopWhenSortingByDate() throws {
        try withTempDir { dir in
            // Папка заведомо старше файла: без правила «папки сверху» она ушла бы вниз.
            let folder = dir.appendingPathComponent("папка")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.modificationDate: date(1)], ofItemAtPath: folder.path)
            try makeFile("свежий.txt", in: dir, modified: date(99))

            #expect(model(at: dir).items.map(\.name) == ["папка", "свежий.txt"])
        }
    }

    /// Прочитанная папка — сокращение для тестов, которым важен только результат.
    private func model(at dir: URL) -> BrowserModel {
        let model = BrowserModel(path: dir)
        model.reload()
        return model
    }

    @Test("до прихода метаданных сортирует по имени, а не по пустым датам")
    func sortsByNameUntilMetadataArrives() {
        // Записи быстрого прохода: metadataLoaded == false, дат нет ни у кого.
        let names = ["в.txt", "а.txt", "б.txt"].map { fastPassItem($0) }

        let sorted = BrowserModel.sorted(names, by: SortSettings(key: "modified", ascending: false))

        // Не порядок выдачи readdir и не обратный ему: именно по имени.
        #expect(sorted.map(\.name) == ["а.txt", "б.txt", "в.txt"])
    }

    @Test("после прихода метаданных пересортировывает по дате")
    func reordersOnceMetadataArrives() throws {
        try withTempDir { dir in
            try makeFile("а-старый.txt", in: dir, modified: date(10))
            try makeFile("я-свежий.txt", in: dir, modified: date(30))

            // Алфавит поставил бы «а-старый» первым — значит порядок задан датой.
            #expect(model(at: dir).items.map(\.name) == ["я-свежий.txt", "а-старый.txt"])
        }
    }

    @Test("сортировка по имени по убыванию действует и на списке без метаданных")
    func respectsDirectionForNameWithoutMetadata() {
        let names = ["а.txt", "б.txt"].map { fastPassItem($0) }

        let sorted = BrowserModel.sorted(names, by: SortSettings(key: "name", ascending: false))

        #expect(sorted.map(\.name) == ["б.txt", "а.txt"])
    }

    @Test("файл без даты изменения уходит вниз, а не ломает порядок остальных")
    func itemWithoutDateSinksToBottom() {
        let dated = FileItem(
            url: URL(fileURLWithPath: "/tmp/с-датой.txt"),
            name: "с-датой.txt",
            isDirectory: false,
            modificationDate: date(10)
        )
        let undated = FileItem(
            url: URL(fileURLWithPath: "/tmp/без-даты.txt"),
            name: "без-даты.txt",
            isDirectory: false,
            modificationDate: nil
        )

        let sorted = BrowserModel.sorted([undated, dated], by: SortSettings(key: "modified", ascending: false))

        #expect(sorted.map(\.name) == ["с-датой.txt", "без-даты.txt"])
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

    @Test("без сохранённого значения умолчание — дата изменения по убыванию")
    func defaultSortIsModifiedDescending() {
        let restored = TabsStore(defaults: makeDefaults()).restoreSort()

        #expect(restored.key == "modified")
        #expect(restored.ascending == false)
    }

    @Test("явно сохранённое «по возрастанию» отличимо от отсутствующего ключа")
    func explicitAscendingIsDistinguishableFromMissingKey() {
        let defaults = makeDefaults()
        // Направление по возрастанию совпадает с тем, что UserDefaults.bool
        // возвращает для отсутствующего ключа, — потому его и стережём.
        TabsStore(defaults: defaults).save(sort: SortSettings(key: "modified", ascending: true))

        #expect(TabsStore(defaults: defaults).restoreSort().ascending)
    }

    @Test("смена сортировки сохраняется сразу, без закрытия приложения")
    func sortIsPersistedOnChange() {
        let defaults = makeDefaults()
        let model = TabsModel(path: home, store: TabsStore(defaults: defaults))

        model.sort = SortSettings(key: "name", ascending: true)

        #expect(TabsStore(defaults: defaults).restoreSort() == SortSettings(key: "name", ascending: true))
    }
}
