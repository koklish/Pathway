import Foundation
import Testing
@testable import PathwayCore

@MainActor
@Suite("Создание документа из модели")
struct BrowserCreateDocumentTests {
    private let template = DocumentTemplate(
        id: "txt", title: "Текстовый документ", defaultName: "Новый документ",
        fileExtension: "txt", group: .basic, content: .empty
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

    /// Отсутствующая заготовка больше не может быть причиной отказа — содержимое
    /// собирается кодом. Осталась причина со стороны файловой системы, и она
    /// по-прежнему должна доходить до пользователя текстом, а не молчанием.
    @Test("при неудаче записи возвращает nil и показывает ошибку, а не молчит")
    func reportsFailure() throws {
        try withTempDir { dir in
            let locked = dir.appendingPathComponent("только-чтение")
            try FileManager.default.createDirectory(
                at: locked, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o500]
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: locked.path
                )
            }

            let model = BrowserModel(path: locked)
            #expect(model.createDocument(template) == nil)
            #expect(model.errorMessage != nil)
        }
    }
}
