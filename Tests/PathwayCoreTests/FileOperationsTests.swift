import Foundation
import Testing
@testable import PathwayCore

@Suite("FileOperations")
struct FileOperationsTests {

    @Test("создаёт новую папку с уникальным именем")
    func createsNewFolder() throws {
        try withTempDir { dir in
            let ops = FileOperations()

            let first = try ops.createFolder(in: dir)
            let second = try ops.createFolder(in: dir)

            #expect(first.lastPathComponent == "Новая папка")
            #expect(second.lastPathComponent == "Новая папка 2")
            #expect(FileManager.default.fileExists(atPath: second.path))
        }
    }

    @Test("переименовывает файл")
    func renamesFile() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("old.txt")
            try Data("x".utf8).write(to: file)

            let renamed = try FileOperations().rename(file, to: "new.txt")

            #expect(renamed.lastPathComponent == "new.txt")
            #expect(FileManager.default.fileExists(atPath: renamed.path))
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test("отклоняет переименование в занятое имя")
    func rejectsRenameToExistingName() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("a.txt")
            try Data("x".utf8).write(to: file)
            try Data("y".utf8).write(to: dir.appendingPathComponent("b.txt"))

            #expect(throws: FileOperationError.nameAlreadyExists) {
                try FileOperations().rename(file, to: "b.txt")
            }
        }
    }

    @Test("отклоняет пустое имя и имя со слэшем")
    func rejectsInvalidNames() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("a.txt")
            try Data("x".utf8).write(to: file)
            let ops = FileOperations()

            #expect(throws: FileOperationError.invalidName) {
                try ops.rename(file, to: "  ")
            }
            #expect(throws: FileOperationError.invalidName) {
                try ops.rename(file, to: "some/name")
            }
        }
    }

    @Test("копирует файл в другую папку")
    func copiesFile() throws {
        try withTempDir { dir in
            let source = dir.appendingPathComponent("file.txt")
            try Data("содержимое".utf8).write(to: source)
            let dest = dir.appendingPathComponent("dest")
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)

            let copied = try FileOperations().copy([source], to: dest)

            #expect(copied.count == 1)
            #expect(try Data(contentsOf: copied[0]) == Data("содержимое".utf8))
            #expect(FileManager.default.fileExists(atPath: source.path), "оригинал остаётся на месте")
        }
    }

    @Test("перемещает файл: в источнике его больше нет")
    func movesFile() throws {
        try withTempDir { dir in
            let source = dir.appendingPathComponent("file.txt")
            try Data("x".utf8).write(to: source)
            let dest = dir.appendingPathComponent("dest")
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)

            let moved = try FileOperations().move([source], to: dest)

            #expect(moved.count == 1)
            #expect(FileManager.default.fileExists(atPath: moved[0].path))
            #expect(!FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test("при конфликте имён в режиме keepBoth создаёт копию с суффиксом")
    func keepsBothOnConflict() throws {
        try withTempDir { dir in
            let source = dir.appendingPathComponent("file.txt")
            try Data("новое".utf8).write(to: source)
            let dest = dir.appendingPathComponent("dest")
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            let existing = dest.appendingPathComponent("file.txt")
            try Data("старое".utf8).write(to: existing)

            let copied = try FileOperations().copy([source], to: dest, onConflict: .keepBoth)

            #expect(copied[0].lastPathComponent == "file 2.txt")
            #expect(try Data(contentsOf: existing) == Data("старое".utf8), "существующий файл не тронут")
        }
    }

    @Test("при конфликте имён в режиме replace перезаписывает файл")
    func replacesOnConflict() throws {
        try withTempDir { dir in
            let source = dir.appendingPathComponent("file.txt")
            try Data("новое".utf8).write(to: source)
            let dest = dir.appendingPathComponent("dest")
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            let existing = dest.appendingPathComponent("file.txt")
            try Data("старое".utf8).write(to: existing)

            let copied = try FileOperations().copy([source], to: dest, onConflict: .replace)

            #expect(copied[0].lastPathComponent == "file.txt")
            #expect(try Data(contentsOf: existing) == Data("новое".utf8))
        }
    }

    @Test("при конфликте имён в режиме skip пропускает файл")
    func skipsOnConflict() throws {
        try withTempDir { dir in
            let source = dir.appendingPathComponent("file.txt")
            try Data("новое".utf8).write(to: source)
            let dest = dir.appendingPathComponent("dest")
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            let existing = dest.appendingPathComponent("file.txt")
            try Data("старое".utf8).write(to: existing)

            let copied = try FileOperations().copy([source], to: dest, onConflict: .skip)

            #expect(copied.isEmpty)
            #expect(try Data(contentsOf: existing) == Data("старое".utf8))
        }
    }

    @Test("перемещает файл в Корзину, а не удаляет безвозвратно")
    func movesToTrash() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("в-корзину.txt")
            try Data("x".utf8).write(to: file)

            var trashed: NSURL?
            try FileManager.default.trashItem(at: file, resultingItemURL: &trashed)
            let restored = try #require(trashed as URL?)
            defer { try? FileManager.default.removeItem(at: restored) }

            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(FileManager.default.fileExists(atPath: restored.path), "файл лежит в Корзине")
        }
    }

    @Test("moveToTrash возвращает число удалённых и пропускает исчезнувшие")
    func moveToTrashCountsRemoved() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("удаляемый.txt")
            try Data("x".utf8).write(to: file)
            let missing = dir.appendingPathComponent("призрак.txt")

            let count = try FileOperations().moveToTrash([missing, file])

            #expect(count == 1)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test("пропускает исчезнувшие файлы, но обрабатывает остальные")
    func skipsMissingSources() throws {
        try withTempDir { dir in
            let existing = dir.appendingPathComponent("real.txt")
            try Data("x".utf8).write(to: existing)
            let missing = dir.appendingPathComponent("призрак.txt")
            let dest = dir.appendingPathComponent("dest")
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)

            let copied = try FileOperations().copy([missing, existing], to: dest)

            #expect(copied.count == 1)
            #expect(copied[0].lastPathComponent == "real.txt")
        }
    }
}
