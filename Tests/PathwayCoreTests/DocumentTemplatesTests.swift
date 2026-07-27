import Testing
@testable import PathwayCore

@Suite("Список шаблонов документов")
struct DocumentTemplatesTests {
    /// Пять пунктов, а не восемь: форматы iWork закрыты, собрать их кодом
    /// нельзя, а хранить файлом — значит вернуть ту самую зависимость от
    /// ресурсного бандла, из-за которой приложение падало при создании.
    @Test("предлагает пять форматов, создаваемых без внешних заготовок")
    func allTemplatesAlwaysAvailable() {
        #expect(DocumentTemplates.all.map(\.id) == ["txt", "rtf", "docx", "xlsx", "pptx"])
    }

    @Test("сохраняет порядок групп: базовые, затем Microsoft")
    func groupOrder() {
        let groups = DocumentTemplates.all.map(\.group)
        #expect(groups == [.basic, .basic, .microsoft, .microsoft, .microsoft])
    }

    @Test("у каждого шаблона свой идентификатор")
    func uniqueIdentifiers() {
        let ids = DocumentTemplates.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("идентификатор совпадает с расширением документа")
    func extensionMatchesIdentifier() {
        #expect(DocumentTemplates.all.allSatisfy { $0.id == $0.fileExtension })
    }

    /// Пустое содержимое допустимо только у текстового файла: контейнерные
    /// форматы нулевой длины приложения считают повреждёнными.
    @Test("пустым создаётся только текстовый документ")
    func onlyPlainTextIsEmpty() {
        for template in DocumentTemplates.all where template.content == .empty {
            #expect(template.id == "txt", "\(template.id) создавался бы пустым файлом")
        }
    }

    @Test("форматы Office собираются как OOXML")
    func officeTemplatesAreOOXML() {
        let kinds = DocumentTemplates.all.filter { $0.group == .microsoft }.map(\.content)
        #expect(kinds == [.ooxml(.word), .ooxml(.excel), .ooxml(.powerPoint)])
    }
}
