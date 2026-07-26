import Foundation
import Testing
@testable import PathwayCore

@Suite("PropertiesBuilder")
struct FilePropertiesTests {

    /// Собирает FileItem из URL так, как это делает список файлов: с размером и
    /// признаком папки. Даты сборщик читает с диска сам, поэтому здесь не нужны.
    private func item(at url: URL) throws -> FileItem {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        return FileItem(
            url: url,
            name: url.lastPathComponent,
            isDirectory: values.isDirectory ?? false,
            size: Int64(values.fileSize ?? 0)
        )
    }

    @Test("один файл: .single, immediateSize равен размеру файла")
    func singleFileHasImmediateSize() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("doc.txt")
            try Data("привет".utf8).write(to: file)

            let subject = PropertiesBuilder.subject(for: [try item(at: file)])

            guard case let .single(props) = subject else {
                Issue.record("ожидался .single")
                return
            }
            #expect(props.immediateSize == Int64("привет".utf8.count))
            #expect(!props.isDirectory)
            #expect(!props.kind.isEmpty)
        }
    }

    @Test("одна папка: .single, immediateSize == nil (размер считается фоном)")
    func singleFolderHasNoImmediateSize() throws {
        try withTempDir { dir in
            let folder = dir.appendingPathComponent("Папка")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

            let subject = PropertiesBuilder.subject(for: [try item(at: folder)])

            guard case let .single(props) = subject else {
                Issue.record("ожидался .single")
                return
            }
            #expect(props.immediateSize == nil)
            #expect(props.isDirectory)
        }
    }

    @Test("два файла в одной папке: .group, count == 2, общее расположение")
    func groupSharesLocation() throws {
        try withTempDir { dir in
            let a = dir.appendingPathComponent("a.txt")
            let b = dir.appendingPathComponent("b.txt")
            try Data("x".utf8).write(to: a)
            try Data("y".utf8).write(to: b)

            let subject = PropertiesBuilder.subject(for: [try item(at: a), try item(at: b)])

            guard case let .group(props) = subject else {
                Issue.record("ожидался .group")
                return
            }
            #expect(props.count == 2)
            // Родитель канонизирован (/var → /private/var), сравниваем от него же.
            #expect(props.location.contains(dir.deletingLastPathComponent().lastPathComponent))
        }
    }

    @Test("файлы из разных папок: расположение — «Разные папки»")
    func groupFromDifferentFoldersReportsMixedLocation() throws {
        try withTempDir { dir in
            let subA = dir.appendingPathComponent("A")
            let subB = dir.appendingPathComponent("B")
            try FileManager.default.createDirectory(at: subA, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: subB, withIntermediateDirectories: false)
            let a = subA.appendingPathComponent("a.txt")
            let b = subB.appendingPathComponent("b.txt")
            try Data("x".utf8).write(to: a)
            try Data("y".utf8).write(to: b)

            let subject = PropertiesBuilder.subject(for: [try item(at: a), try item(at: b)])

            guard case let .group(props) = subject else {
                Issue.record("ожидался .group")
                return
            }
            #expect(props.location == "Разные папки")
        }
    }

    @Test("файлы с одним расширением дают общий тип, с разными — «Файлы разных типов»")
    func groupKindsCollapseWhenExtensionsMatch() throws {
        try withTempDir { dir in
            let a = dir.appendingPathComponent("a.txt")
            let b = dir.appendingPathComponent("b.txt")
            let c = dir.appendingPathComponent("c.pdf")
            for url in [a, b, c] { try Data("x".utf8).write(to: url) }

            let same = PropertiesBuilder.subject(for: [try item(at: a), try item(at: b)])
            let mixed = PropertiesBuilder.subject(for: [try item(at: a), try item(at: c)])

            guard case let .group(sameProps) = same, case let .group(mixedProps) = mixed else {
                Issue.record("ожидался .group")
                return
            }
            #expect(sameProps.kinds != "Файлы разных типов")
            #expect(mixedProps.kinds == "Файлы разных типов")
        }
    }

    @Test("файл только для чтения: доступ — «Только чтение»")
    func readOnlyFileReportsReadOnlyAccess() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("ro.txt")
            try Data("x".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

            let subject = PropertiesBuilder.subject(for: [try item(at: file)])

            guard case let .single(props) = subject else {
                Issue.record("ожидался .single")
                return
            }
            #expect(props.access == "Только чтение")
        }
    }

    @Test("файл с записью: доступ — «Чтение и запись»")
    func writableFileReportsReadWriteAccess() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("rw.txt")
            try Data("x".utf8).write(to: file)

            let subject = PropertiesBuilder.subject(for: [try item(at: file)])

            guard case let .single(props) = subject else {
                Issue.record("ожидался .single")
                return
            }
            #expect(props.access == "Чтение и запись")
        }
    }
}
