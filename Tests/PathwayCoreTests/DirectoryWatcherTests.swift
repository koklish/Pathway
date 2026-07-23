import Foundation
import Testing
@testable import PathwayCore

/// Подменный наблюдатель: запоминает папку и умеет послать событие вручную.
/// Настоящий FSEvents здесь не нужен — проверяется реакция модели, а не ядро.
@MainActor
final class FakeDirectoryWatcher: DirectoryWatching {
    private(set) var watched: URL?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var onChange: (@MainActor (DirectoryChange) -> Void)?

    var isWatching: Bool { watched != nil }

    func start(_ directory: URL, onChange: @escaping @MainActor (DirectoryChange) -> Void) {
        watched = directory
        self.onChange = onChange
        startCount += 1
    }

    func stop() {
        watched = nil
        onChange = nil
        stopCount += 1
    }

    /// Изображает событие от файловой системы.
    func emit(hasModifications: Bool = false) {
        onChange?(DirectoryChange(hasModifications: hasModifications))
    }
}

@MainActor
@Suite("Слежение за папкой")
struct DirectoryWatcherTests {

    // MARK: - Дифф состава

    @Test("внешнее событие добавляет появившийся файл в список")
    func externalChangeAddsNewFile() async throws {
        try await withTempDirAsync { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("старый.txt"))
            let watcher = FakeDirectoryWatcher()
            let model = BrowserModel(path: dir, watcher: watcher)
            model.reloadAsync()
            await model.waitForLoad()

            try Data("y".utf8).write(to: dir.appendingPathComponent("новый.txt"))
            watcher.emit()
            await model.waitForRefresh()

            #expect(model.items.map(\.name) == ["новый.txt", "старый.txt"])
        }
    }

    @Test("внешнее событие убирает исчезнувший файл")
    func externalChangeRemovesDeletedFile() async throws {
        try await withTempDirAsync { dir in
            let doomed = dir.appendingPathComponent("исчезнет.txt")
            try Data("x".utf8).write(to: doomed)
            try Data("y".utf8).write(to: dir.appendingPathComponent("останется.txt"))
            let watcher = FakeDirectoryWatcher()
            let model = BrowserModel(path: dir, watcher: watcher)
            model.reloadAsync()
            await model.waitForLoad()

            try FileManager.default.removeItem(at: doomed)
            watcher.emit()
            await model.waitForRefresh()

            #expect(model.items.map(\.name) == ["останется.txt"])
        }
    }

    @Test("уцелевшие записи сохраняют прочитанные метаданные, а не перечитывают их заново")
    func survivingItemsKeepMetadata() async throws {
        try await withTempDirAsync { dir in
            try Data("содержимое".utf8).write(to: dir.appendingPathComponent("старый.txt"))
            let watcher = FakeDirectoryWatcher()
            let model = BrowserModel(path: dir, watcher: watcher)
            model.reloadAsync()
            await model.waitForLoad()

            try Data("y".utf8).write(to: dir.appendingPathComponent("новый.txt"))
            watcher.emit()
            // Ждём только дифф, до второго прохода за метаданными.
            await model.waitForRefresh()

            let old = try #require(model.items.first { $0.name == "старый.txt" })
            #expect(old.metadataLoaded)
            #expect(old.size == Int64("содержимое".utf8.count))
        }
    }

    @Test("событие с модификацией помечает метаданные всех записей устаревшими")
    func modificationEventInvalidatesMetadata() async throws {
        try await withTempDirAsync { dir in
            let file = dir.appendingPathComponent("растёт.txt")
            try Data("мало".utf8).write(to: file)
            let watcher = FakeDirectoryWatcher()
            let model = BrowserModel(path: dir, watcher: watcher)
            model.reloadAsync()
            await model.waitForLoad()

            try Data("сильно больше прежнего".utf8).write(to: file)
            watcher.emit(hasModifications: true)
            await model.waitForRefresh()
            await model.waitForMetadata()

            let item = try #require(model.items.first)
            #expect(item.size == Int64("сильно больше прежнего".utf8.count))
        }
    }

    // MARK: - Выделение

    @Test("исчезнувший файл вычищается из выделения, уцелевший в нём остаётся")
    func selectionDropsVanishedItems() async throws {
        try await withTempDirAsync { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("исчезнет.txt"))
            try Data("y".utf8).write(to: dir.appendingPathComponent("останется.txt"))
            let watcher = FakeDirectoryWatcher()
            let model = BrowserModel(path: dir, watcher: watcher)
            model.reloadAsync()
            await model.waitForLoad()
            // От model.items, а не от склеенного URL: DirectoryLoader канонизирует пути.
            model.pane.selection = Set(model.items.map(\.url))
            let doomed = try #require(model.items.first { $0.name == "исчезнет.txt" }).url
            let kept = try #require(model.items.first { $0.name == "останется.txt" }).url

            try FileManager.default.removeItem(at: doomed)
            watcher.emit()
            await model.waitForRefresh()

            #expect(model.pane.selection == [kept])
        }
    }

    // MARK: - Защиты

    @Test("событие во время инлайн-переименования не трогает список")
    func changeIgnoredWhileRenaming() async throws {
        try await withTempDirAsync { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("старый.txt"))
            let watcher = FakeDirectoryWatcher()
            let model = BrowserModel(path: dir, watcher: watcher)
            model.reloadAsync()
            await model.waitForLoad()

            model.isRenaming = true
            try Data("y".utf8).write(to: dir.appendingPathComponent("новый.txt"))
            watcher.emit()
            await model.waitForRefresh()

            #expect(model.items.map(\.name) == ["старый.txt"])
        }
    }

    @Test("ошибка чтения при внешнем обновлении не показывает алерт и не чистит список")
    func failedRefreshKeepsListAndStaysSilent() async throws {
        try await withTempDirAsync { dir in
            let folder = dir.appendingPathComponent("папка")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("x".utf8).write(to: folder.appendingPathComponent("файл.txt"))
            let watcher = FakeDirectoryWatcher()
            let model = BrowserModel(path: folder, watcher: watcher)
            model.reloadAsync()
            await model.waitForLoad()

            // Папку удалили под ногами — чтение обречено.
            try FileManager.default.removeItem(at: folder)
            watcher.emit()
            await model.waitForRefresh()

            #expect(model.errorMessage == nil)
            #expect(model.items.map(\.name) == ["файл.txt"])
        }
    }

    @Test("событие, пришедшее после смены папки, не переписывает новый список")
    func staleEventDoesNotOverwriteNewFolder() async throws {
        try await withTempDirAsync { dir in
            let first = dir.appendingPathComponent("первая")
            let second = dir.appendingPathComponent("вторая")
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
            try Data("x".utf8).write(to: first.appendingPathComponent("из-первой.txt"))
            try Data("y".utf8).write(to: second.appendingPathComponent("из-второй.txt"))

            let watcher = FakeDirectoryWatcher()
            let model = BrowserModel(path: first, watcher: watcher)
            model.reloadAsync()
            await model.waitForLoad()

            // Событие первой папки и тут же переход во вторую.
            watcher.emit()
            model.navigate(to: second)
            await model.waitForLoad()
            await model.waitForRefresh()

            #expect(model.items.map(\.name) == ["из-второй.txt"])
        }
    }

    // MARK: - Жизненный цикл

    @Test("загрузка папки включает слежение за ней")
    func loadStartsWatching() async throws {
        try await withTempDirAsync { dir in
            let watcher = FakeDirectoryWatcher()
            let model = BrowserModel(path: dir, watcher: watcher)

            model.reloadAsync()
            await model.waitForLoad()

            // По .path, а не по URL: pane.path хранит адрес каталога с завершающим
            // слэшем, и сравнение целых URL разошлось бы на нём.
            #expect(watcher.watched?.path == dir.resolvingSymlinksInPath().path)
        }
    }

    @Test("переход в другую папку переставляет слежение, а не заводит второе")
    func navigationMovesWatch() async throws {
        try await withTempDirAsync { dir in
            let sub = dir.appendingPathComponent("вложенная")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
            let watcher = FakeDirectoryWatcher()
            let model = BrowserModel(path: dir, watcher: watcher)
            model.reloadAsync()
            await model.waitForLoad()

            model.navigate(to: sub)
            await model.waitForLoad()

            #expect(watcher.watched?.path == sub.resolvingSymlinksInPath().path)
            #expect(watcher.startCount == 2)
        }
    }

    /// Настоящий FSEvents, а не фейк: только он проверяет, что поток создаётся
    /// с рабочими параметрами и что его освобождение — оно идёт с очереди самого
    /// FSEvents, а не с главного потока — не роняет процесс.
    @Test("настоящий наблюдатель замечает создание файла и переживает освобождение", .timeLimit(.minutes(1)))
    func realWatcherReportsCreation() async throws {
        try await withTempDirAsync { dir in
            let watcher = DirectoryWatcher()
            let received = Received()
            watcher.start(dir) { change in received.store(change) }

            // FSEvents доставляет первое событие пачки сразу (NoDefer),
            // но само уведомление ядра асинхронно — даём ему дойти.
            try Data("x".utf8).write(to: dir.appendingPathComponent("новый.txt"))
            for _ in 0..<100 where received.change == nil {
                try await Task.sleep(for: .milliseconds(50))
            }

            #expect(received.change != nil)
            watcher.stop()
        }
    }

    /// Копилка события: колбэк приходит на главном потоке, а ждём мы в тесте.
    @MainActor
    final class Received {
        private(set) var change: DirectoryChange?
        func store(_ change: DirectoryChange) { self.change = change }
    }

    /// Сквозная проверка всего пути: модель с наблюдателем по умолчанию — то
    /// есть с настоящим FSEvents, как в приложении — должна показать созданный
    /// извне файл сама. Остальные тесты идут через подмену и такого не поймали бы.
    @Test("модель с настоящим наблюдателем показывает созданный извне файл", .timeLimit(.minutes(1)))
    func modelSeesExternalFile() async throws {
        try await withTempDirAsync { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("старый.txt"))
            let model = BrowserModel(path: dir)
            model.reloadAsync()
            await model.waitForLoad()

            try Data("y".utf8).write(to: dir.appendingPathComponent("новый.txt"))
            for _ in 0..<100 where model.items.count < 2 {
                try await Task.sleep(for: .milliseconds(50))
            }

            #expect(model.items.map(\.name) == ["новый.txt", "старый.txt"])
            model.cancelLoad()
        }
    }

    @Test("отмена загрузки останавливает слежение")
    func cancelLoadStopsWatching() async throws {
        try await withTempDirAsync { dir in
            let watcher = FakeDirectoryWatcher()
            let model = BrowserModel(path: dir, watcher: watcher)
            model.reloadAsync()
            await model.waitForLoad()

            model.cancelLoad()

            #expect(!watcher.isWatching)
            #expect(watcher.stopCount == 1)
        }
    }
}
