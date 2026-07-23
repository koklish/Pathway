import Testing
@testable import PathwayCore

/// Подменённый поиск приложений: ничего не спрашивает у системы, иначе результат
/// зависел бы от того, что установлено на машине, где запустили тесты.
private struct StubAppLookup: AppLookup {
    let installed: Set<String>
    func isInstalled(bundleID: String) -> Bool { installed.contains(bundleID) }
}

@Suite("Список шаблонов документов")
struct DocumentTemplatesTests {
    @Test("без установленных приложений оставляет только базовые пункты")
    func basicOnly() {
        let available = DocumentTemplates.available(with: StubAppLookup(installed: []))
        #expect(available.map(\.id) == ["txt", "rtf"])
    }

    @Test("с установленным Office добавляет пункты Word, Excel и PowerPoint")
    func microsoftGroup() {
        let lookup = StubAppLookup(installed: [
            "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint",
        ])
        let available = DocumentTemplates.available(with: lookup)
        #expect(available.map(\.id) == ["txt", "rtf", "docx", "xlsx", "pptx"])
    }

    @Test("с установленным iWork добавляет пункты Pages, Numbers и Keynote")
    func appleGroup() {
        let lookup = StubAppLookup(installed: [
            "com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.apple.iWork.Keynote",
        ])
        let available = DocumentTemplates.available(with: lookup)
        #expect(available.map(\.id) == ["txt", "rtf", "pages", "numbers", "key"])
    }

    @Test("показывает обе группы сразу, а не одну вместо другой")
    func bothGroups() {
        let lookup = StubAppLookup(installed: ["com.microsoft.Word", "com.apple.iWork.Pages"])
        let available = DocumentTemplates.available(with: lookup)
        #expect(available.map(\.id) == ["txt", "rtf", "docx", "pages"])
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

    @Test("текстовый файл и RTF не требуют установленного приложения")
    func basicNeedNoApp() {
        let basic = DocumentTemplates.all.filter { $0.group == .basic }
        #expect(basic.allSatisfy { $0.requiredApp == nil })
    }

    @Test("имя файла заготовки совпадает с расширением документа")
    func extensionMatchesIdentifier() {
        #expect(DocumentTemplates.all.allSatisfy { $0.id == $0.fileExtension })
    }
}
