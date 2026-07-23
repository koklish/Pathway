import Foundation
import Testing
@testable import PathwayCore

@MainActor
@Suite("Создание документа из модели")
struct BrowserCreateDocumentTests {
    private let template = DocumentTemplate(
        id: "txt", title: "Текстовый документ", defaultName: "Новый документ",
        fileExtension: "txt", group: .basic
    )

    @Test("создаёт документ в текущей папке и возвращает его адрес")
    func createsInCurrentFolder() throws {
        try withTempDir { dir in
            let model = BrowserModel(path: dir)
            let url = model.createDocument(template)
            #expect(url?.lastPathComponent == "Новый документ.txt")
            #expect(FileManager.default.fileExists(atPath: url?.path ?? ""))
        }
    }

    @Test("при неудаче возвращает nil и показывает ошибку, а не молчит")
    func reportsFailure() throws {
        try withTempDir { dir in
            let missing = DocumentTemplate(
                id: "нет-такого", title: "Не существует", defaultName: "Документ",
                fileExtension: "xyz", group: .basic
            )
            let model = BrowserModel(path: dir)
            #expect(model.createDocument(missing) == nil)
            #expect(model.errorMessage != nil)
        }
    }
}
