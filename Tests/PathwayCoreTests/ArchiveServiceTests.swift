import Foundation
import Testing
@testable import PathwayCore

@Suite("ArchiveService")
struct ArchiveServiceTests {

    // MARK: - Распознавание архивов

    @Test("распознаёт поддерживаемые расширения архивов")
    func recognizesArchiveExtensions() {
        let archives = [
            "a.zip", "b.tar", "c.tar.gz", "d.tgz", "e.tar.bz2",
            "f.tbz", "g.tbz2", "h.tar.xz", "i.txz", "j.7z", "k.rar", "l.ZIP",
        ]
        for name in archives {
            #expect(ArchiveService.isArchive(URL(fileURLWithPath: "/tmp/\(name)")), "\(name) должен считаться архивом")
        }
    }

    @Test("не считает архивами обычные файлы")
    func rejectsNonArchives() {
        let plain = ["a.txt", "b.pdf", "c.gz", "d", "e.zipx", "f.tar.txt"]
        for name in plain {
            #expect(!ArchiveService.isArchive(URL(fileURLWithPath: "/tmp/\(name)")), "\(name) не должен считаться архивом")
        }
    }

    // MARK: - Вспомогательное

    /// Создаёт папку `source` с файлом и подпапкой — материал для архивации.
    private func makeSampleFolder(in dir: URL, name: String = "Материалы") throws -> URL {
        let folder = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("вложенная"), withIntermediateDirectories: true)
        try Data("привет".utf8).write(to: folder.appendingPathComponent("файл.txt"))
        try Data("глубже".utf8).write(to: folder.appendingPathComponent("вложенная/ещё.txt"))
        return folder
    }

    private func contentsMatch(_ extracted: URL) throws -> Bool {
        let text = try String(contentsOf: extracted.appendingPathComponent("файл.txt"), encoding: .utf8)
        let nested = try String(contentsOf: extracted.appendingPathComponent("вложенная/ещё.txt"), encoding: .utf8)
        return text == "привет" && nested == "глубже"
    }

    // MARK: - Создание и распаковка (roundtrip)

    @Test("создаёт и распаковывает архив каждого формата", arguments: ArchiveFormat.allCases)
    func roundtrip(format: ArchiveFormat) async throws {
        try await withTempDirAsync { dir in
            let folder = try makeSampleFolder(in: dir)
            let service = ArchiveService()

            let archive = try await service.create(
                items: [folder], format: format, password: nil,
                archiveName: "Мой архив", in: dir)

            #expect(archive.lastPathComponent == "Мой архив.\(format.fileExtension)")
            #expect(FileManager.default.fileExists(atPath: archive.path))

            let target = dir.appendingPathComponent("выход")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let extracted = try await service.extract(archive: archive, to: target, password: nil)

            // Один элемент верхнего уровня — извлекается без обёртки.
            #expect(extracted.lastPathComponent == "Материалы")
            #expect(try contentsMatch(extracted))
        }
    }

    @Test("архив из нескольких элементов распаковывается в папку с именем архива")
    func multipleTopLevelItemsGetWrapperFolder() async throws {
        try await withTempDirAsync { dir in
            let a = dir.appendingPathComponent("один.txt")
            let b = dir.appendingPathComponent("два.txt")
            try Data("1".utf8).write(to: a)
            try Data("2".utf8).write(to: b)
            let service = ArchiveService()

            let archive = try await service.create(
                items: [a, b], format: .zip, password: nil,
                archiveName: "Пара", in: dir)

            let target = dir.appendingPathComponent("выход")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let extracted = try await service.extract(archive: archive, to: target, password: nil)

            #expect(extracted.lastPathComponent == "Пара")
            #expect(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("один.txt").path))
            #expect(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("два.txt").path))
        }
    }

    @Test("конфликт имён решается суффиксом « 2»")
    func nameConflictsGetSuffix() async throws {
        try await withTempDirAsync { dir in
            let folder = try makeSampleFolder(in: dir)
            let service = ArchiveService()

            let first = try await service.create(
                items: [folder], format: .zip, password: nil, archiveName: "Архив", in: dir)
            let second = try await service.create(
                items: [folder], format: .zip, password: nil, archiveName: "Архив", in: dir)
            #expect(first.lastPathComponent == "Архив.zip")
            #expect(second.lastPathComponent == "Архив 2.zip")

            // Распаковка рядом с уже существующей папкой «Материалы».
            let extracted = try await service.extract(archive: first, to: dir, password: nil)
            #expect(extracted.lastPathComponent == "Материалы 2")
            #expect(try contentsMatch(extracted))
        }
    }

    @Test("сообщает прогресс от 0 до 1")
    func reportsProgress() async throws {
        try await withTempDirAsync { dir in
            let folder = try makeSampleFolder(in: dir)
            let service = ArchiveService()
            let archive = try await service.create(
                items: [folder], format: .zip, password: nil, archiveName: "Архив", in: dir)

            let box = ProgressBox()
            let target = dir.appendingPathComponent("выход")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            _ = try await service.extract(archive: archive, to: target, password: nil) { value in
                box.append(value)
            }
            let values = box.values
            #expect(!values.isEmpty)
            #expect(values.allSatisfy { $0 >= 0 && $0 <= 1 })
            #expect(values == values.sorted())
        }
    }

    // MARK: - Пароль (zip)

    @Test("zip с паролем распаковывается с верным паролем")
    func passwordProtectedZipRoundtrip() async throws {
        try await withTempDirAsync { dir in
            let folder = try makeSampleFolder(in: dir)
            let service = ArchiveService()
            let archive = try await service.create(
                items: [folder], format: .zip, password: "секрет", archiveName: "Тайна", in: dir)

            let target = dir.appendingPathComponent("выход")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let extracted = try await service.extract(archive: archive, to: target, password: "секрет")
            #expect(try contentsMatch(extracted))
        }
    }

    @Test("зашифрованный zip без пароля — ошибка passwordRequired")
    func encryptedZipWithoutPasswordFails() async throws {
        try await withTempDirAsync { dir in
            let folder = try makeSampleFolder(in: dir)
            let service = ArchiveService()
            let archive = try await service.create(
                items: [folder], format: .zip, password: "секрет", archiveName: "Тайна", in: dir)

            await #expect(throws: ArchiveError.passwordRequired) {
                _ = try await service.extract(archive: archive, to: dir, password: nil)
            }
        }
    }

    @Test("зашифрованный zip с неверным паролем — ошибка wrongPassword")
    func encryptedZipWithWrongPasswordFails() async throws {
        try await withTempDirAsync { dir in
            let folder = try makeSampleFolder(in: dir)
            let service = ArchiveService()
            let archive = try await service.create(
                items: [folder], format: .zip, password: "секрет", archiveName: "Тайна", in: dir)

            await #expect(throws: ArchiveError.wrongPassword) {
                _ = try await service.extract(archive: archive, to: dir, password: "не тот")
            }
        }
    }

    // MARK: - Отмена

    @Test("отмена распаковки не оставляет временных папок")
    func cancellationLeavesNoTempFolders() async throws {
        try await withTempDirAsync { dir in
            // Большой архив, чтобы распаковка не успела завершиться мгновенно.
            let folder = dir.appendingPathComponent("Большая")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let blob = Data(repeating: 0xAB, count: 200_000)
            for i in 0..<300 {
                try blob.write(to: folder.appendingPathComponent("файл-\(i).bin"))
            }
            let service = ArchiveService()
            let archive = try await service.create(
                items: [folder], format: .zip, password: nil, archiveName: "Большой", in: dir)

            let target = dir.appendingPathComponent("выход")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let task = Task {
                try await service.extract(archive: archive, to: target, password: nil)
            }
            try? await Task.sleep(for: .milliseconds(30))
            task.cancel()
            let result = await task.result
            #expect(throws: (any Error).self) { try result.get() }

            let leftovers = try FileManager.default.contentsOfDirectory(atPath: target.path)
                .filter { $0.hasPrefix(".pathway-extract") }
            #expect(leftovers.isEmpty)
        }
    }
}

/// Потокобезопасный сборщик значений прогресса.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ value: Double) {
        lock.lock(); storage.append(value); lock.unlock()
    }
    var values: [Double] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
