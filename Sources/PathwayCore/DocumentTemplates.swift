import Foundation

/// Группа пунктов в подменю «Создать». Порядок значений задаёт порядок групп в
/// меню: сначала то, что работает на любой машине, затем Microsoft, затем Apple.
public enum TemplateGroup: Sendable, Equatable {
    case basic, microsoft, apple
}

/// Заготовка документа. Файл создаётся копированием, поэтому `id` служит
/// одновременно именем файла-заготовки в Resources/Templates.
public struct DocumentTemplate: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let defaultName: String
    public let fileExtension: String
    public let group: TemplateGroup

    public init(
        id: String,
        title: String,
        defaultName: String,
        fileExtension: String,
        group: TemplateGroup
    ) {
        self.id = id
        self.title = title
        self.defaultName = defaultName
        self.fileExtension = fileExtension
        self.group = group
    }
}

public enum DocumentTemplates {
    /// Полный список — он же состав подменю: наличие Office и iWork не
    /// проверяется намеренно. Заготовка валидна сама по себе, а меню, зависящее
    /// от машины, объяснить коллеге труднее, чем пункт, открывающийся не тем
    /// приложением. Плата названа явно: на машине без Word созданный .docx
    /// откроется тем, что назначено системой.
    public static let all: [DocumentTemplate] = [
        DocumentTemplate(
            id: "txt", title: "Текстовый документ", defaultName: "Новый документ",
            fileExtension: "txt", group: .basic
        ),
        DocumentTemplate(
            id: "rtf", title: "Документ RTF", defaultName: "Новый документ",
            fileExtension: "rtf", group: .basic
        ),
        DocumentTemplate(
            id: "docx", title: "Документ Word", defaultName: "Новый документ",
            fileExtension: "docx", group: .microsoft
        ),
        DocumentTemplate(
            id: "xlsx", title: "Книга Excel", defaultName: "Новая книга",
            fileExtension: "xlsx", group: .microsoft
        ),
        DocumentTemplate(
            id: "pptx", title: "Презентация PowerPoint", defaultName: "Новая презентация",
            fileExtension: "pptx", group: .microsoft
        ),
        DocumentTemplate(
            id: "pages", title: "Документ Pages", defaultName: "Новый документ",
            fileExtension: "pages", group: .apple
        ),
        DocumentTemplate(
            id: "numbers", title: "Таблица Numbers", defaultName: "Новая таблица",
            fileExtension: "numbers", group: .apple
        ),
        DocumentTemplate(
            id: "key", title: "Презентация Keynote", defaultName: "Новая презентация",
            fileExtension: "key", group: .apple
        ),
    ]

    /// Папка с заготовками внутри бандла. Промах означал бы, что ресурсы не
    /// подключены в Package.swift, — это ошибка сборки, а не выполнения.
    public static var templatesRoot: URL {
        guard let url = Bundle.module.url(forResource: "Templates", withExtension: nil) else {
            preconditionFailure("Заготовки документов не подключены к PathwayCore")
        }
        return url
    }
}
