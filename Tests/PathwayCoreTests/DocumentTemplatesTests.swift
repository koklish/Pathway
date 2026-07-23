import Testing
@testable import PathwayCore

@Suite("Список шаблонов документов")
struct DocumentTemplatesTests {
    @Test("предлагает все восемь пунктов, а не только те, чьё приложение установлено")
    func allTemplatesAlwaysAvailable() {
        #expect(
            DocumentTemplates.all.map(\.id)
                == ["txt", "rtf", "docx", "xlsx", "pptx", "pages", "numbers", "key"]
        )
    }

    @Test("сохраняет порядок групп: базовые, Microsoft, Apple")
    func groupOrder() {
        let groups = DocumentTemplates.all.map(\.group)
        #expect(groups == [.basic, .basic, .microsoft, .microsoft, .microsoft, .apple, .apple, .apple])
    }

    @Test("у каждого шаблона свой идентификатор")
    func uniqueIdentifiers() {
        let ids = DocumentTemplates.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("имя файла заготовки совпадает с расширением документа")
    func extensionMatchesIdentifier() {
        #expect(DocumentTemplates.all.allSatisfy { $0.id == $0.fileExtension })
    }
}
