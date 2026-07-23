import Foundation
import Testing
@testable import PathwayCore

@Suite("Создание документа из заготовки")
struct CreateDocumentTests {
    private let template = DocumentTemplate(
        id: "docx", title: "Документ Word", defaultName: "Новый документ",
        fileExtension: "docx", group: .microsoft
    )

    /// Кладёт заготовку во временную папку: настоящий бандл здесь не нужен,
    /// проверяется само копирование.
    private func makeTemplatesRoot(
        in dir: URL,
        content: Data = Data([0x50, 0x4B, 0x03, 0x04])
    ) throws -> URL {
        let root = dir.appendingPathComponent("Templates")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try content.write(to: root.appendingPathComponent("docx"))
        return root
    }

    @Test("создаёт файл с именем и расширением из шаблона")
    func createsNamedFile() throws {
        try withTempDir { dir in
            let root = try makeTemplatesRoot(in: dir)
            let url = try FileOperations().createDocument(template, in: dir, templatesRoot: root)
            #expect(url.lastPathComponent == "Новый документ.docx")
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("второй документ получает имя со счётчиком, а не перезаписывает первый")
    func secondDocumentGetsSuffix() throws {
        try withTempDir { dir in
            let root = try makeTemplatesRoot(in: dir)
            let operations = FileOperations()
            let first = try operations.createDocument(template, in: dir, templatesRoot: root)
            let second = try operations.createDocument(template, in: dir, templatesRoot: root)
            #expect(second.lastPathComponent == "Новый документ 2.docx")
            #expect(FileManager.default.fileExists(atPath: first.path))
        }
    }

    @Test("содержимое совпадает с заготовкой байт в байт")
    func copiesContentExactly() throws {
        try withTempDir { dir in
            let content = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x06, 0x00])
            let root = try makeTemplatesRoot(in: dir, content: content)
            let url = try FileOperations().createDocument(template, in: dir, templatesRoot: root)
            #expect(try Data(contentsOf: url) == content)
        }
    }

    @Test("без заготовки бросает ошибку, а не создаёт пустой файл")
    func missingTemplateThrows() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("Пусто")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            #expect(throws: FileOperationError.templateMissing) {
                try FileOperations().createDocument(template, in: dir, templatesRoot: root)
            }
            let created = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(!created.contains { $0.hasSuffix(".docx") })
        }
    }
}
