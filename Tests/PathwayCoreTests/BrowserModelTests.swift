import Foundation
import Testing
@testable import PathwayCore

@MainActor
@Suite("BrowserModel — связка навигации и файловых операций")
struct BrowserModelTests {

    @Test("загружает содержимое текущей папки")
    func loadsCurrentDirectory() throws {
        try withTempDir { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("file.txt"))
            let model = BrowserModel(path: dir)

            model.reload()

            #expect(model.items.map(\.name) == ["file.txt"])
        }
    }

    @Test("переход в папку перезагружает список")
    func navigationReloadsItems() throws {
        try withTempDir { dir in
            let sub = dir.appendingPathComponent("sub")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
            try Data("x".utf8).write(to: sub.appendingPathComponent("inner.txt"))
            let model = BrowserModel(path: dir)
            model.reload()

            model.navigate(to: sub)

            #expect(model.items.map(\.name) == ["inner.txt"])
        }
    }

    @Test("создаёт папку и показывает её в списке")
    func createsFolderAndShowsIt() throws {
        try withTempDir { dir in
            let model = BrowserModel(path: dir)
            model.reload()

            model.createFolder()

            #expect(model.items.map(\.name) == ["Новая папка"])
        }
    }

    @Test("вставка после вырезания перемещает файл")
    func pasteAfterCutMovesFile() throws {
        try withTempDir { dir in
            let source = dir.appendingPathComponent("файл.txt")
            try Data("x".utf8).write(to: source)
            let dest = dir.appendingPathComponent("dest")
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)

            let model = BrowserModel(path: dir, pasteboard: PasteboardService(isolatedForTesting: true))
            model.reload()
            model.pane.selection = [source]
            model.cut()

            model.navigate(to: dest)
            model.paste()

            #expect(model.items.map(\.name) == ["файл.txt"])
            #expect(!FileManager.default.fileExists(atPath: source.path), "оригинал перемещён")
        }
    }

    @Test("вставка после копирования оставляет оригинал на месте")
    func pasteAfterCopyKeepsOriginal() throws {
        try withTempDir { dir in
            let source = dir.appendingPathComponent("файл.txt")
            try Data("x".utf8).write(to: source)
            let dest = dir.appendingPathComponent("dest")
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)

            let model = BrowserModel(path: dir, pasteboard: PasteboardService(isolatedForTesting: true))
            model.reload()
            model.pane.selection = [source]
            model.copy()

            model.navigate(to: dest)
            model.paste()

            #expect(model.items.map(\.name) == ["файл.txt"])
            #expect(FileManager.default.fileExists(atPath: source.path), "оригинал остался")
        }
    }

    @Test("переименование обновляет список")
    func renameUpdatesItems() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("старое.txt")
            try Data("x".utf8).write(to: file)
            let model = BrowserModel(path: dir)
            model.reload()

            model.rename(file, to: "новое.txt")

            #expect(model.items.map(\.name) == ["новое.txt"])
            #expect(model.errorMessage == nil)
        }
    }

    @Test("показывает понятную ошибку при переименовании в занятое имя")
    func reportsRenameConflict() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("a.txt")
            try Data("x".utf8).write(to: file)
            try Data("y".utf8).write(to: dir.appendingPathComponent("b.txt"))
            let model = BrowserModel(path: dir)
            model.reload()

            model.rename(file, to: "b.txt")

            #expect(model.errorMessage != nil)
            #expect(model.items.map(\.name) == ["a.txt", "b.txt"], "файлы не изменились")
        }
    }

    @Test("сообщает об отсутствии доступа вместо падения")
    func reportsPermissionDenied() {
        let model = BrowserModel(path: URL(fileURLWithPath: "/root-нет-доступа-\(UUID().uuidString)"))

        model.reload()

        #expect(model.items.isEmpty)
        #expect(model.errorMessage != nil)
    }

    @Test("сортирует по имени в обе стороны, папки всегда сверху")
    func sortsByNameBothDirections() throws {
        try withTempDir { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
            try Data("x".utf8).write(to: dir.appendingPathComponent("b.txt"))
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("папка"), withIntermediateDirectories: false)
            let model = BrowserModel(path: dir)
            model.reload()

            model.sort(by: "name", ascending: false)

            #expect(model.items.map(\.name) == ["папка", "b.txt", "a.txt"])
        }
    }

    @Test("сортирует по размеру")
    func sortsBySize() throws {
        try withTempDir { dir in
            try Data(repeating: 0, count: 100).write(to: dir.appendingPathComponent("маленький.bin"))
            try Data(repeating: 0, count: 5000).write(to: dir.appendingPathComponent("большой.bin"))
            let model = BrowserModel(path: dir)
            model.reload()

            model.sort(by: "size", ascending: true)

            #expect(model.items.map(\.name) == ["маленький.bin", "большой.bin"])
        }
    }

    @Test("форматирует размер файла и прочерк для папки")
    func formatsSizeColumn() throws {
        try withTempDir { dir in
            try Data(repeating: 0, count: 2048).write(to: dir.appendingPathComponent("файл.bin"))
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("папка"), withIntermediateDirectories: false)
            let model = BrowserModel(path: dir)
            model.reload()

            let folder = try #require(model.items.first { $0.isDirectory })
            let file = try #require(model.items.first { !$0.isDirectory })

            #expect(model.text(for: folder, column: "size") == "—")
            #expect(model.text(for: file, column: "size").contains("2"))
            #expect(model.text(for: file, column: "name") == "файл.bin")
        }
    }

    @Test("удаление в Корзину убирает файл из списка")
    func moveSelectionToTrashRemovesItem() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("удаляемый.txt")
            try Data("x".utf8).write(to: file)
            let model = BrowserModel(path: dir)
            model.reload()
            model.pane.selection = [file]

            model.moveSelectionToTrash()

            #expect(model.items.isEmpty)
            #expect(model.pane.selection.isEmpty)
        }
    }

    @Test("двойной клик по папке открывает её")
    func openFolderNavigates() throws {
        try withTempDir { dir in
            let sub = dir.appendingPathComponent("папка")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
            let model = BrowserModel(path: dir)
            model.reload()

            model.open(FileItem(url: sub, name: "папка", isDirectory: true))

            #expect(model.pane.path.path == sub.path)
        }
    }

    @Test("копирование в конкретную папку работает для drag & drop")
    func copiesToExplicitDestination() throws {
        try withTempDir { dir in
            let source = dir.appendingPathComponent("файл.txt")
            try Data("x".utf8).write(to: source)
            let dest = dir.appendingPathComponent("dest")
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            let model = BrowserModel(path: dir)
            model.reload()

            model.copy([source], to: dest)

            #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("файл.txt").path))
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test("строит хлебные крошки от корня до текущей папки")
    func buildsBreadcrumbs() {
        let model = BrowserModel(path: URL(fileURLWithPath: "/Users/alex/Documents"))

        let crumbs = model.breadcrumbs

        #expect(crumbs.map(\.name) == ["Macintosh HD", "Users", "alex", "Documents"])
        #expect(crumbs.first?.url.path == "/")
        #expect(crumbs.last?.url.path == "/Users/alex/Documents")
    }

    @Test("в корне крошки состоят из одного элемента")
    func breadcrumbsAtRoot() {
        let model = BrowserModel(path: URL(fileURLWithPath: "/"))

        #expect(model.breadcrumbs.map(\.name) == ["Macintosh HD"])
    }

    @Test("статус показывает количество папок и файлов")
    func statusTextCountsItems() throws {
        try withTempDir { dir in
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("папка"), withIntermediateDirectories: false)
            try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
            try Data("x".utf8).write(to: dir.appendingPathComponent("b.txt"))
            let model = BrowserModel(path: dir)

            model.reload()

            #expect(model.statusText == "Папок: 1, файлов: 2")
        }
    }

    @Test("статус показывает количество выделенных объектов")
    func statusTextShowsSelection() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("a.txt")
            try Data("x".utf8).write(to: file)
            let model = BrowserModel(path: dir)
            model.reload()

            model.pane.selection = [file]

            #expect(model.statusText.contains("Выделено: 1"))
        }
    }

    @Test("для дерева возвращает только подпапки, без файлов")
    func subdirectoriesSkipFiles() throws {
        try withTempDir { dir in
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("папка"), withIntermediateDirectories: false)
            try Data("x".utf8).write(to: dir.appendingPathComponent("файл.txt"))
            let model = BrowserModel(path: dir)

            let subdirs = model.subdirectories(of: dir)

            #expect(subdirs.map(\.name) == ["папка"])
        }
    }

    @Test("для недоступной папки дерево возвращает пустой список без ошибки")
    func subdirectoriesOfUnreadableFolderAreEmpty() {
        let model = BrowserModel(path: FileManager.default.homeDirectoryForCurrentUser)

        let subdirs = model.subdirectories(of: URL(fileURLWithPath: "/нет-такой-\(UUID().uuidString)"))

        #expect(subdirs.isEmpty)
        #expect(model.errorMessage == nil, "раскрытие узла дерева не должно показывать алерт")
    }

    @Test("учитывает настройку показа скрытых файлов")
    func respectsShowHiddenSetting() throws {
        try withTempDir { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("видимый.txt"))
            try Data("x".utf8).write(to: dir.appendingPathComponent(".скрытый"))
            let model = BrowserModel(path: dir)

            model.reload()
            #expect(model.items.count == 1)

            model.showHiddenFiles = true
            model.reload()
            #expect(model.items.count == 2)
        }
    }
}
