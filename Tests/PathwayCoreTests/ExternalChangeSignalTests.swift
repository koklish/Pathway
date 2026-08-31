import Foundation
import Testing

@testable import PathwayCore

@Suite("Сигнал о внешних изменениях")
@MainActor
struct ExternalChangeSignalTests {

    @Test("правка существующего файла поднимает счётчик изменений")
    func modificationBumpsCounter() async throws {
        try await withTempDirAsync { dir in
            try "старое".write(
                to: dir.appendingPathComponent("файл.txt"), atomically: true, encoding: .utf8
            )
            let watcher = FakeDirectoryWatcher()
            let model = BrowserModel(path: dir, watcher: watcher)
            model.reloadAsync()
            await model.waitForLoad()

            let before = model.externalChangeCount
            // Число файлов при этом не меняется — по нему панель коммитов не
            // узнала бы о сохранении в редакторе и показывала бы список
            // изменений на момент открытия.
            watcher.emit(hasModifications: true)
            await model.waitForRefresh()

            #expect(model.externalChangeCount > before)
            #expect(model.items.count == 1)
        }
    }

    @Test("появление файла тоже поднимает счётчик")
    func creationBumpsCounter() async throws {
        try await withTempDirAsync { dir in
            let watcher = FakeDirectoryWatcher()
            let model = BrowserModel(path: dir, watcher: watcher)
            model.reloadAsync()
            await model.waitForLoad()
            let before = model.externalChangeCount

            try "новый".write(
                to: dir.appendingPathComponent("новый.txt"), atomically: true, encoding: .utf8
            )
            watcher.emit()
            await model.waitForRefresh()

            #expect(model.externalChangeCount > before)
        }
    }
}
