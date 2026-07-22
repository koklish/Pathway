import Foundation
import Testing

@testable import PathwayCore

@Suite("Кэш каталогов и фоновая загрузка")
@MainActor
struct DirectoryCacheTests {
    @Test("возврат в открытую папку показывает список мгновенно, до чтения диска")
    func cachedFolderShowsInstantly() async throws {
        try await withTempDirAsync { dir in
            let sub = dir.appendingPathComponent("sub")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
            try Data("x".utf8).write(to: sub.appendingPathComponent("inner.txt"))

            let model = BrowserModel(path: dir)
            model.navigate(to: sub)
            await model.waitForLoad()
            model.navigate(to: dir)
            await model.waitForLoad()

            // Возврат: список обязан быть заполнен сразу, без ожидания загрузки.
            model.navigate(to: sub)
            #expect(model.items.map(\.name) == ["inner.txt"])
        }
    }

    @Test("кэш не путает папки с показом скрытых файлов и без него")
    func cacheSeparatesHiddenMode() async throws {
        try await withTempDirAsync { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("видимый.txt"))
            try Data("x".utf8).write(to: dir.appendingPathComponent(".скрытый"))

            let model = BrowserModel(path: dir)
            model.reloadAsync()
            await model.waitForLoad()
            #expect(model.items.map(\.name) == ["видимый.txt"])

            model.showHiddenFiles = true
            model.reloadAsync()
            await model.waitForLoad()

            #expect(model.items.count == 2)
        }
    }

    @Test("после создания папки список обновляется, а не отдаётся из кэша")
    func invalidatesAfterFileOperation() async throws {
        try await withTempDirAsync { dir in
            let model = BrowserModel(path: dir)
            model.reloadAsync()
            await model.waitForLoad()
            #expect(model.items.isEmpty)

            model.createFolder()

            #expect(model.items.count == 1)
        }
    }

    @Test("копирование в другую папку не оставляет её кэш устаревшим")
    func invalidatesDestinationCache() async throws {
        try await withTempDirAsync { dir in
            let source = dir.appendingPathComponent("файл.txt")
            let dest = dir.appendingPathComponent("приёмник")
            try Data("x".utf8).write(to: source)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)

            let model = BrowserModel(path: dir)
            // Открываем приёмник, чтобы он попал в кэш пустым.
            model.navigate(to: dest)
            await model.waitForLoad()
            #expect(model.items.isEmpty)

            model.navigate(to: dir)
            await model.waitForLoad()
            model.copy([source], to: dest)

            model.navigate(to: dest)
            await model.waitForLoad()

            #expect(model.items.map(\.name) == ["файл.txt"])
        }
    }

    @Test("быстрое переключение папок не подменяет содержимое открытой")
    func laterNavigationWins() async throws {
        try await withTempDirAsync { dir in
            let first = dir.appendingPathComponent("first")
            let second = dir.appendingPathComponent("second")
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
            try Data("x".utf8).write(to: first.appendingPathComponent("один.txt"))
            try Data("x".utf8).write(to: second.appendingPathComponent("два.txt"))

            let model = BrowserModel(path: dir)
            // Уходим во вторую папку, не дожидаясь загрузки первой.
            model.navigate(to: first)
            model.navigate(to: second)
            await model.waitForLoad()

            #expect(model.pane.path.standardizedFileURL.path == second.standardizedFileURL.path)
            #expect(model.items.map(\.name) == ["два.txt"])
        }
    }

    @Test("быстрый проход даёт имена и папки без чтения метаданных")
    func loadNamesSkipsMetadata() throws {
        try withTempDir { dir in
            let sub = dir.appendingPathComponent("папка")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
            try Data("содержимое".utf8).write(to: dir.appendingPathComponent("файл.txt"))

            let names = try DirectoryLoader().loadNames(directory: dir)

            #expect(names.map(\.name) == ["папка", "файл.txt"])
            #expect(names.allSatisfy { !$0.metadataLoaded })
            #expect(names.first?.isDirectory == true)
        }
    }

    @Test("быстрый проход определяет тип так же, как полная загрузка")
    func fastPathMatchesFullLoad() throws {
        try withTempDir { dir in
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("папка"), withIntermediateDirectories: false)
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("вторая"), withIntermediateDirectories: false)
            try Data("x".utf8).write(to: dir.appendingPathComponent("файл.txt"))
            try Data("x".utf8).write(to: dir.appendingPathComponent("другой.dat"))
            // Ссылка на папку: d_type пометит её DT_LNK, а не DT_DIR.
            try FileManager.default.createSymbolicLink(
                at: dir.appendingPathComponent("ссылка"),
                withDestinationURL: dir.appendingPathComponent("папка"))

            let loader = DirectoryLoader()
            let fast = try loader.loadNames(directory: dir)
            let full = try loader.load(directory: dir)

            #expect(fast.map(\.name) == full.map(\.name))
            #expect(fast.map(\.isDirectory) == full.map(\.isDirectory))
        }
    }

    @Test("быстрый проход скрывает точечные файлы и показывает их по настройке")
    func fastPathRespectsHiddenSetting() throws {
        try withTempDir { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("видимый.txt"))
            try Data("x".utf8).write(to: dir.appendingPathComponent(".скрытый"))
            let loader = DirectoryLoader()

            #expect(try loader.loadNames(directory: dir).map(\.name) == ["видимый.txt"])
            #expect(try loader.loadNames(directory: dir, showHidden: true).count == 2)
        }
    }

    @Test("быстрый проход сообщает об ошибке для несуществующей папки")
    func fastPathThrowsForMissingDirectory() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")

        #expect(throws: (any Error).self) {
            try DirectoryLoader().loadNames(directory: missing)
        }
    }

    @Test("второй проход добирает размеры и даты")
    func loadMetadataFillsDetails() throws {
        try withTempDir { dir in
            try Data("содержимое".utf8).write(to: dir.appendingPathComponent("файл.txt"))
            let loader = DirectoryLoader()
            let names = try loader.loadNames(directory: dir)

            let detailed = loader.loadMetadata(for: names)

            let file = try #require(detailed.first { $0.name == "файл.txt" })
            #expect(file.metadataLoaded)
            #expect(file.size == Int64("содержимое".utf8.count))
            #expect(file.modificationDate != nil)
        }
    }

    @Test("вытесняет давно неиспользованные папки, не разрастаясь без предела")
    func evictsOldEntries() {
        let cache = DirectoryCache(limit: 2)
        let a = URL(fileURLWithPath: "/tmp/a")
        let b = URL(fileURLWithPath: "/tmp/b")
        let c = URL(fileURLWithPath: "/tmp/c")
        let item = FileItem(url: a, name: "x", isDirectory: false)

        cache.store([item], for: a, showHidden: false)
        cache.store([item], for: b, showHidden: false)
        cache.store([item], for: c, showHidden: false)

        #expect(cache.items(for: a, showHidden: false) == nil)
        #expect(cache.items(for: c, showHidden: false) != nil)
    }
}
