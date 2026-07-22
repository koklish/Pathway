import Foundation
import Testing
@testable import PathwayCore

/// Временная папка с заданными файлами; удаляется после теста.
func withTempDir(_ body: (URL) throws -> Void) throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("PathwayTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

/// То же, что withTempDir, но для тестов с фоновой загрузкой.
@MainActor
func withTempDirAsync(_ body: @MainActor (URL) async throws -> Void) async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("PathwayTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir)
}

@Suite("DirectoryLoader")
struct DirectoryLoaderTests {

    @Test("возвращает содержимое папки: папки первыми, затем файлы по имени")
    func listsFolderContents() throws {
        try withTempDir { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("b.txt"))
            try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("Folder"), withIntermediateDirectories: false)

            let items = try DirectoryLoader().load(directory: dir)

            #expect(items.map(\.name) == ["Folder", "a.txt", "b.txt"])
            #expect(items[0].isDirectory)
            #expect(!items[1].isDirectory)
        }
    }

    @Test("по умолчанию скрывает файлы, начинающиеся с точки")
    func hidesDotFilesByDefault() throws {
        try withTempDir { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("visible.txt"))
            try Data("x".utf8).write(to: dir.appendingPathComponent(".hidden"))

            let items = try DirectoryLoader().load(directory: dir)

            #expect(items.map(\.name) == ["visible.txt"])
        }
    }

    @Test("показывает скрытые файлы, когда showHidden = true")
    func showsHiddenFilesWhenRequested() throws {
        try withTempDir { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("visible.txt"))
            try Data("x".utf8).write(to: dir.appendingPathComponent(".hidden"))

            let items = try DirectoryLoader().load(directory: dir, showHidden: true)

            #expect(items.map(\.name) == [".hidden", "visible.txt"])
        }
    }

    @Test("читает размер файла и дату изменения")
    func readsSizeAndModificationDate() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("data.bin")
            try Data(repeating: 0, count: 2048).write(to: file)

            let items = try DirectoryLoader().load(directory: dir)

            #expect(items.count == 1)
            #expect(items[0].size == 2048)
            #expect(items[0].modificationDate != nil)
        }
    }

    @Test("бросает ошибку для несуществующей папки")
    func throwsForMissingDirectory() throws {
        try withTempDir { dir in
            let missing = dir.appendingPathComponent("нет-такой-папки")

            #expect(throws: (any Error).self) {
                try DirectoryLoader().load(directory: missing)
            }
        }
    }
}
