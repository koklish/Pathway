import Foundation
import Testing

@testable import PathwayCore

@Suite("Извлечение текста из файлов")
struct TextExtractorTests {

    private let extractor = SystemTextExtractor()

    private func write(_ data: Data, named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Собирает .docx с заданным текстом абзаца.
    ///
    /// Заготовка OOXMLBuilder распаковывается, `document.xml` подменяется, и
    /// всё пакуется обратно тем же bsdtar. Своего упаковщика в тестах нет и не
    /// нужно: собирать zip вручную ради одного файла значило бы повторить
    /// OOXMLBuilder, а он умеет только пустой документ.
    private func makeDocx(withParagraph text: String, in dir: URL) throws -> URL {
        let unpacked = dir.appendingPathComponent("распакованный-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)

        let template = try write(OOXMLBuilder.data(for: .word), named: "заготовка.docx", in: dir)
        try run("/usr/bin/bsdtar", ["-x", "-f", template.path, "-C", unpacked.path])

        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:body><w:p><w:r><w:t>\(text)</w:t></w:r></w:p></w:body></w:document>
        """
        try Data(document.utf8).write(to: unpacked.appendingPathComponent("word/document.xml"))

        let result = dir.appendingPathComponent("Документ-\(UUID().uuidString).docx")
        try run("/usr/bin/bsdtar", ["-c", "-f", result.path, "--format", "zip", "-C", unpacked.path, "."])
        return result
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    // MARK: - Обычный текст

    @Test("читает UTF-8 текст")
    func readsUTF8() async throws {
        try await withTempDirAsync { dir in
            let url = try write(Data("договор поставки".utf8), named: "заметка.txt", in: dir)
            #expect(try await extractor.text(of: url) == "договор поставки")
        }
    }

    @Test("читает текст в Windows-1251, а не возвращает nil")
    func readsWindows1251() async throws {
        try await withTempDirAsync { dir in
            let text = "договор поставки"
            let data = try #require(text.data(using: .windowsCP1251))
            let url = try write(data, named: "из-windows.csv", in: dir)
            #expect(try await extractor.text(of: url) == text)
        }
    }

    @Test("возвращает nil для файла с нулевым байтом в начале: это бинарник, а не текст")
    func rejectsBinaryContent() async throws {
        try await withTempDirAsync { dir in
            var data = Data("начало".utf8)
            data.append(contentsOf: [0x00, 0x01, 0x02])
            let url = try write(data, named: "дамп.log", in: dir)
            #expect(try await extractor.text(of: url) == nil)
        }
    }

    @Test("возвращает nil для расширения вне списка")
    func rejectsUnknownExtension() async throws {
        try await withTempDirAsync { dir in
            let url = try write(Data("договор".utf8), named: "картинка.png", in: dir)
            #expect(try await extractor.text(of: url) == nil)
        }
    }

    @Test("читает исходники наравне с документами")
    func readsSourceCode() async throws {
        try await withTempDirAsync { dir in
            let url = try write(Data("func договор() {}".utf8), named: "Модель.swift", in: dir)
            #expect(try await extractor.text(of: url) == "func договор() {}")
        }
    }

    @Test("файл без расширения не читается: тип неизвестен, а гадать по содержимому дороже пользы")
    func rejectsExtensionlessFile() async throws {
        try await withTempDirAsync { dir in
            let url = try write(Data("договор".utf8), named: "README", in: dir)
            #expect(try await extractor.text(of: url) == nil)
        }
    }

    @Test("расширение опознаётся независимо от регистра")
    func extensionIsCaseInsensitive() async throws {
        try await withTempDirAsync { dir in
            let url = try write(Data("договор".utf8), named: "ЗАМЕТКА.TXT", in: dir)
            #expect(try await extractor.text(of: url) == "договор")
        }
    }

    // MARK: - OOXML

    @Test("извлекает текст из docx и снимает XML-теги")
    func readsDocx() async throws {
        try await withTempDirAsync { dir in
            let url = try write(OOXMLBuilder.data(for: .word), named: "Документ.docx", in: dir)
            let text = try #require(try await extractor.text(of: url))
            #expect(!text.contains("<w:t>"))
            #expect(!text.contains("<?xml"))
        }
    }

    @Test("извлекает из docx настоящий текст абзаца")
    func readsDocxContent() async throws {
        try await withTempDirAsync { dir in
            // Заготовка OOXMLBuilder пуста — на ней не видно, доходит ли текст
            // из документа до выдачи. Поэтому документ с текстом собирается
            // здесь: bsdtar пересобирает распакованное обратно в zip.
            let url = try makeDocx(withParagraph: "Поставщик ООО Ромашка", in: dir)
            let text = try #require(try await extractor.text(of: url))
            #expect(text.contains("Поставщик ООО Ромашка"))
        }
    }

    @Test("читает xlsx без sharedStrings: отсутствие необязательной части не отказ")
    func readsXlsxWithoutSharedStrings() async throws {
        try await withTempDirAsync { dir in
            // Заготовка Excel — пустая таблица, sharedStrings.xml в ней нет.
            // Именно этот случай ломался, когда части перечислялись поимённо.
            let url = try write(OOXMLBuilder.data(for: .excel), named: "Таблица.xlsx", in: dir)
            #expect(try await extractor.text(of: url) != nil)
        }
    }

    @Test("читает pptx")
    func readsPptx() async throws {
        try await withTempDirAsync { dir in
            let url = try write(OOXMLBuilder.data(for: .powerPoint), named: "Презентация.pptx", in: dir)
            #expect(try await extractor.text(of: url) != nil)
        }
    }

    @Test("повреждённый docx бросает ошибку, а не выдаёт мусор")
    func brokenDocxThrows() async throws {
        try await withTempDirAsync { dir in
            let url = try write(Data("не архив вовсе".utf8), named: "Битый.docx", in: dir)
            await #expect(throws: (any Error).self) { try await extractor.text(of: url) }
        }
    }

    // MARK: - Отбор кандидатов

    @Test("расширение читаемого файла опознаётся без обращения к диску")
    func recognizesReadableExtensions() {
        #expect(SystemTextExtractor.isReadable(URL(fileURLWithPath: "/тест/заметка.txt")))
        #expect(SystemTextExtractor.isReadable(URL(fileURLWithPath: "/тест/Документ.docx")))
        #expect(SystemTextExtractor.isReadable(URL(fileURLWithPath: "/тест/Акт.pdf")))
        #expect(!SystemTextExtractor.isReadable(URL(fileURLWithPath: "/тест/фото.jpg")))
        #expect(!SystemTextExtractor.isReadable(URL(fileURLWithPath: "/тест/Архив.zip")))
    }

    @Test("старые форматы .doc и .xls читаемыми не считаются")
    func oldOfficeFormatsAreNotReadable() {
        #expect(!SystemTextExtractor.isReadable(URL(fileURLWithPath: "/тест/Старый.doc")))
        #expect(!SystemTextExtractor.isReadable(URL(fileURLWithPath: "/тест/Старая.xls")))
    }
}
