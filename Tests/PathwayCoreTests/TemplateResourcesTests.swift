import Foundation
import Testing
@testable import PathwayCore

@Suite("Заготовки документов в бандле")
struct TemplateResourcesTests {
    @Test("для каждого шаблона в бандле лежит заготовка")
    func everyTemplateHasFile() {
        for template in DocumentTemplates.all {
            let url = DocumentTemplates.templatesRoot.appendingPathComponent(template.id)
            #expect(FileManager.default.fileExists(atPath: url.path), "нет заготовки \(template.id)")
        }
    }

    /// Пустой текстовый файл — нормальный документ, а вот контейнерные форматы
    /// нулевой длины приложение считает повреждёнными. Ошибка вылезла бы только
    /// при открытии документа, поэтому проверяется здесь.
    @Test("заготовки контейнерных форматов непустые")
    func containerTemplatesAreNotEmpty() throws {
        for template in DocumentTemplates.all where template.id != "txt" {
            let url = DocumentTemplates.templatesRoot.appendingPathComponent(template.id)
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            #expect(size > 0, "заготовка \(template.id) пуста")
        }
    }

    @Test("заготовки OOXML и iWork — ZIP-контейнеры")
    func containersAreZip() throws {
        for id in ["docx", "xlsx", "pptx", "pages", "numbers", "key"] {
            let url = DocumentTemplates.templatesRoot.appendingPathComponent(id)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            #expect(try handle.read(upToCount: 2) == Data([0x50, 0x4B]), "заготовка \(id) не ZIP")
        }
    }
}
