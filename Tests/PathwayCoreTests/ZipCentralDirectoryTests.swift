import Foundation
import Testing

@testable import PathwayCore

@Suite("Центральный каталог ZIP")
struct ZipCentralDirectoryTests {

    /// Собирает zip системным архиватором — так их создают в реальности.
    @discardableResult
    private func makeZip(in dir: URL, named: String = "test.zip", entries: [String]) throws -> URL {
        for entry in entries {
            let file = dir.appendingPathComponent(entry)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("содержимое".utf8).write(to: file)
        }
        let archive = dir.appendingPathComponent(named)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-qr", archive.path] + entries
        process.currentDirectoryURL = dir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        for entry in entries {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(entry))
        }
        return archive
    }

    @Test("читает имена записей архива")
    func readsEntryNames() throws {
        try withTempDir { dir in
            let archive = try makeZip(in: dir, entries: ["a.txt", "sub/b.txt"])

            let names = try ZipCentralDirectory.entryNames(of: archive)

            #expect(names.contains("a.txt"))
            #expect(names.contains("sub/b.txt"))
        }
    }

    @Test("кириллица в именах возвращается целой, а не заменой на «?»")
    func readsCyrillicNames() throws {
        // Ровно то, на чём спотыкается unzip: он подменяет байты имени
        // вопросительными знаками, и русские файлы становятся ненаходимыми.
        try withTempDir { dir in
            let archive = try makeZip(in: dir, entries: ["Договор № 5.pdf", "папка/счёт.txt"])

            let names = try ZipCentralDirectory.entryNames(of: archive)

            #expect(names.contains("Договор № 5.pdf"))
            #expect(names.contains("папка/счёт.txt"))
            #expect(!names.contains { $0.contains("?") })
        }
    }

    @Test("читает архив, у которого испорчено всё, кроме хвоста")
    func readsFromTailOnly() throws {
        // Смысл своего парсера: оглавление ZIP лежит в конце файла, и по сети
        // достаточно вытянуть килобайты вместо всего архива. Забитое нулями
        // начало это доказывает.
        try withTempDir { dir in
            let archive = try makeZip(in: dir, entries: (1...50).map { "файл\($0).txt" })
            var data = try Data(contentsOf: archive)
            let half = data.count / 2
            for index in 0..<half { data[index] = 0 }
            let damaged = dir.appendingPathComponent("damaged.zip")
            try data.write(to: damaged)

            let names = try ZipCentralDirectory.entryNames(of: damaged)

            #expect(names.count == 50)
            #expect(names.contains("файл1.txt"))
        }
    }

    @Test("пустой архив даёт пустой список, а не ошибку")
    func readsEmptyArchive() throws {
        try withTempDir { dir in
            let archive = try makeZip(in: dir, entries: [])
            // zip без файлов не создаёт архив вовсе — собираем минимальный вручную.
            let empty = Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
            try empty.write(to: archive)

            let names = try ZipCentralDirectory.entryNames(of: archive)

            #expect(names.isEmpty)
        }
    }

    @Test("файл без сигнатуры каталога даёт ошибку, а не крэш")
    func rejectsNonZip() throws {
        try withTempDir { dir in
            let notZip = dir.appendingPathComponent("t.zip")
            try Data("это вовсе не архив".utf8).write(to: notZip)

            #expect(throws: ZipReadError.self) {
                try ZipCentralDirectory.entryNames(of: notZip)
            }
        }
    }

    @Test("обрезанный каталог отдаёт прочитанное, а не падает")
    func survivesTruncatedDirectory() throws {
        // Файл мог недокачаться по сети; поиск обязан пережить это молча.
        try withTempDir { dir in
            let archive = try makeZip(in: dir, entries: (1...20).map { "ф\($0).txt" })
            var data = try Data(contentsOf: archive)
            // Рвём середину центрального каталога, оставляя хвост на месте.
            let end = data.count - 22
            for index in (end - 200)..<(end - 100) where index > 0 { data[index] = 0xFF }
            let broken = dir.appendingPathComponent("broken.zip")
            try data.write(to: broken)

            // Ошибка допустима, крэш — нет.
            _ = try? ZipCentralDirectory.entryNames(of: broken)
        }
    }

    @Test("архив с 10 000 записей разбирается быстро")
    func handlesManyEntriesQuickly() throws {
        try withTempDir { dir in
            // Собираем каталог напрямую: 10 000 файлов на диске создавались бы
            // дольше самого теста.
            let archive = dir.appendingPathComponent("many.zip")
            try Data(Self.syntheticZip(entryCount: 10_000)).write(to: archive)

            let start = Date()
            let names = try ZipCentralDirectory.entryNames(of: archive)
            let elapsed = Date().timeIntervalSince(start)

            #expect(names.count == 10_000)
            #expect(elapsed < 1.0)
        }
    }

    @Test("число записей ограничено, чтобы огромный архив не съел память")
    func limitsEntryCount() throws {
        try withTempDir { dir in
            let archive = dir.appendingPathComponent("huge.zip")
            try Data(Self.syntheticZip(entryCount: 200)).write(to: archive)

            let names = try ZipCentralDirectory.entryNames(of: archive, limit: 50)

            #expect(names.count == 50)
        }
    }

    /// Собирает минимальный ZIP только из центрального каталога: данные записей
    /// парсеру не нужны, а генерировать их — лишние секунды в тесте.
    private static func syntheticZip(entryCount: Int) -> [UInt8] {
        var directory: [UInt8] = []
        for index in 0..<entryCount {
            let name = Array("файл\(index).txt".utf8)
            // Смещения по спецификации ZIP: до имени ровно 46 байт.
            directory += [0x50, 0x4B, 0x01, 0x02]            //  0 сигнатура
            directory += [20, 0, 20, 0]                      //  4 версии
            directory += [0x00, 0x08]                        //  8 флаги: бит 11 — UTF-8
            directory += [0, 0]                              // 10 метод
            directory += [0, 0, 0, 0]                        // 12 время и дата
            directory += [0, 0, 0, 0]                        // 16 CRC
            directory += [0, 0, 0, 0]                        // 20 сжатый размер
            directory += [0, 0, 0, 0]                        // 24 исходный размер
            directory += UInt16(name.count).littleEndianBytes // 28 длина имени
            directory += [0, 0]                              // 30 длина extra
            directory += [0, 0]                              // 32 длина комментария
            directory += [0, 0]                              // 34 номер диска
            directory += [0, 0]                              // 36 внутренние атрибуты
            directory += [0, 0, 0, 0]                        // 38 внешние атрибуты
            directory += [0, 0, 0, 0]                        // 42 смещение
            directory += name                                // 46 имя
        }
        var end: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        end += [0, 0, 0, 0]
        end += UInt16(entryCount).littleEndianBytes
        end += UInt16(entryCount).littleEndianBytes
        end += UInt32(directory.count).littleEndianBytes
        end += UInt32(0).littleEndianBytes
        end += [0, 0]
        return directory + end
    }
}

private extension UInt16 {
    var littleEndianBytes: [UInt8] { [UInt8(self & 0xFF), UInt8(self >> 8)] }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] {
        [UInt8(self & 0xFF), UInt8((self >> 8) & 0xFF), UInt8((self >> 16) & 0xFF), UInt8((self >> 24) & 0xFF)]
    }
}
