import Foundation
import Testing
@testable import PathwayCore

@Suite("Сборка заготовок OOXML в памяти")
struct OOXMLBuilderTests {
    /// Распаковывает данные системным unzip и отдаёт список имён частей.
    ///
    /// Проверять настоящим распаковщиком, а не только сигнатурой «PK», важно:
    /// ровно на этом ломается «пустой файл с нужным расширением» — первые байты
    /// подделать легко, а собрать читаемый контейнер нет. Word ведёт себя как
    /// unzip: не найдя центрального каталога, объявляет документ повреждённым.
    private func entries(of data: Data) throws -> [String] {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "unzip не прочитал контейнер")
        return String(decoding: output, as: UTF8.self)
            .split(separator: "\n").map(String.init)
    }

    /// Достаёт содержимое одной части — чтобы поймать перепутанные местами
    /// имена и данные: список частей при такой ошибке остаётся правильным.
    private func content(of name: String, in data: Data) throws -> String {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", file.path, name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }

    @Test("контейнер начинается с сигнатуры ZIP, а не пуст")
    func startsWithZipSignature() {
        for kind in [OOXMLKind.word, .excel, .powerPoint] {
            let data = OOXMLBuilder.data(for: kind)
            #expect(data.count > 4, "контейнер \(kind) пуст")
            #expect(Array(data.prefix(4)) == [0x50, 0x4B, 0x03, 0x04], "\(kind) не ZIP")
        }
    }

    @Test("каждый контейнер распаковывается без ошибок")
    func unzipReadsEveryContainer() throws {
        for kind in [OOXMLKind.word, .excel, .powerPoint] {
            let names = try entries(of: OOXMLBuilder.data(for: kind))
            #expect(!names.isEmpty, "в контейнере \(kind) нет частей")
        }
    }

    @Test("документ Word содержит обязательные части")
    func wordHasRequiredParts() throws {
        let names = try entries(of: OOXMLBuilder.data(for: .word))
        #expect(names.contains("[Content_Types].xml"))
        #expect(names.contains("_rels/.rels"))
        #expect(names.contains("word/document.xml"))
    }

    @Test("книга Excel содержит лист, презентация PowerPoint — слайд")
    func excelAndPowerPointHaveOwnParts() throws {
        let excel = try entries(of: OOXMLBuilder.data(for: .excel))
        #expect(excel.contains("xl/workbook.xml"))
        #expect(excel.contains("xl/worksheets/sheet1.xml"))

        let powerPoint = try entries(of: OOXMLBuilder.data(for: .powerPoint))
        #expect(powerPoint.contains("ppt/presentation.xml"))
        #expect(powerPoint.contains("ppt/slides/slide1.xml"))
    }

    @Test("части лежат под своими именами, а не перепутаны местами")
    func partsMatchTheirNames() throws {
        let data = OOXMLBuilder.data(for: .word)
        let document = try content(of: "word/document.xml", in: data)
        #expect(document.hasPrefix("<?xml"), "часть пуста или не XML")
        #expect(document.contains("<w:document"), "в document.xml лежит не документ")
    }

    /// Эталон из спецификации ZIP: crc32("123456789") == 0xCBF43926. Ошибка в
    /// таблице дала бы контейнер, который открывается не всяким распаковщиком.
    @Test("CRC32 совпадает с эталонным значением")
    func crc32MatchesReference() {
        #expect(OOXMLBuilder.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test("пустые данные дают нулевой CRC32")
    func crc32OfEmptyIsZero() {
        #expect(OOXMLBuilder.crc32(Data()) == 0)
    }
}
