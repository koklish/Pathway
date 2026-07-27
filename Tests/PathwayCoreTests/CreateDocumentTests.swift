import Foundation
import Testing
@testable import PathwayCore

@Suite("Создание документа")
struct CreateDocumentTests {
    private func template(_ id: String) throws -> DocumentTemplate {
        try #require(DocumentTemplates.all.first { $0.id == id }, "нет шаблона \(id)")
    }

    @Test("создаёт файл с именем и расширением из шаблона")
    func createsNamedFile() throws {
        try withTempDir { dir in
            let url = try FileOperations().createDocument(try template("docx"), in: dir)
            #expect(url.lastPathComponent == "Новый документ.docx")
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("второй документ получает имя со счётчиком, а не перезаписывает первый")
    func secondDocumentGetsSuffix() throws {
        try withTempDir { dir in
            let operations = FileOperations()
            let first = try operations.createDocument(try template("docx"), in: dir)
            let second = try operations.createDocument(try template("docx"), in: dir)
            #expect(second.lastPathComponent == "Новый документ 2.docx")
            #expect(FileManager.default.fileExists(atPath: first.path))
        }
    }

    /// Пустой текстовый файл — нормальный документ; здесь нулевая длина
    /// правильна, в отличие от контейнерных форматов ниже.
    @Test("текстовый документ создаётся пустым")
    func textDocumentIsEmpty() throws {
        try withTempDir { dir in
            let url = try FileOperations().createDocument(try template("txt"), in: dir)
            #expect(try Data(contentsOf: url).isEmpty)
        }
    }

    @Test("документ RTF начинается с управляющего слова формата")
    func rtfHasHeader() throws {
        try withTempDir { dir in
            let url = try FileOperations().createDocument(try template("rtf"), in: dir)
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.hasPrefix("{\\rtf1"))
        }
    }

    /// Главная проверка правки: контейнерные форматы получают настоящий ZIP.
    /// Файл нулевой длины Word и Excel считают повреждённым — именно это и
    /// отличает сгенерированный документ от «пустого файла с расширением».
    @Test("документы Office — непустые ZIP-контейнеры, а не пустые файлы")
    func officeDocumentsAreRealContainers() throws {
        try withTempDir { dir in
            for id in ["docx", "xlsx", "pptx"] {
                let url = try FileOperations().createDocument(try template(id), in: dir)
                let data = try Data(contentsOf: url)
                #expect(data.count > 4, "\(id) пуст")
                #expect(Array(data.prefix(4)) == [0x50, 0x4B, 0x03, 0x04], "\(id) не ZIP")
            }
        }
    }

    /// Ради этого свойства всё и переделывалось: раньше создание документа
    /// читало заготовку из ресурсного бандла, и не доехавший до бандла файл
    /// ронял приложение целиком (fatalError внутри Bundle.module). Теперь
    /// содержимое рождается в коде, и снаружи зависеть не от чего.
    @Test("создание не зависит от файлов рядом с приложением")
    func doesNotDependOnExternalFiles() throws {
        try withTempDir { dir in
            for template in DocumentTemplates.all {
                let url = try FileOperations().createDocument(template, in: dir)
                #expect(FileManager.default.fileExists(atPath: url.path), "не создан \(template.id)")
            }
        }
    }
}
