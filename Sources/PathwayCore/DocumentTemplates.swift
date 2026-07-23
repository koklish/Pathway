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
    /// Bundle ID приложения, открывающего такой файл; nil — пункт доступен всегда.
    public let requiredApp: String?

    public init(
        id: String,
        title: String,
        defaultName: String,
        fileExtension: String,
        group: TemplateGroup,
        requiredApp: String?
    ) {
        self.id = id
        self.title = title
        self.defaultName = defaultName
        self.fileExtension = fileExtension
        self.group = group
        self.requiredApp = requiredApp
    }
}

/// Поиск установленных приложений. Протокол, а не прямой вызов NSWorkspace:
/// иначе состав меню нельзя было бы проверить без реального Office на машине.
public protocol AppLookup: Sendable {
    func isInstalled(bundleID: String) -> Bool
}

public enum DocumentTemplates {
    public static let all: [DocumentTemplate] = [
        DocumentTemplate(
            id: "txt", title: "Текстовый документ", defaultName: "Новый документ",
            fileExtension: "txt", group: .basic, requiredApp: nil
        ),
        DocumentTemplate(
            id: "rtf", title: "Документ RTF", defaultName: "Новый документ",
            fileExtension: "rtf", group: .basic, requiredApp: nil
        ),
        DocumentTemplate(
            id: "docx", title: "Документ Word", defaultName: "Новый документ",
            fileExtension: "docx", group: .microsoft, requiredApp: "com.microsoft.Word"
        ),
        DocumentTemplate(
            id: "xlsx", title: "Книга Excel", defaultName: "Новая книга",
            fileExtension: "xlsx", group: .microsoft, requiredApp: "com.microsoft.Excel"
        ),
        DocumentTemplate(
            id: "pptx", title: "Презентация PowerPoint", defaultName: "Новая презентация",
            fileExtension: "pptx", group: .microsoft, requiredApp: "com.microsoft.Powerpoint"
        ),
        DocumentTemplate(
            id: "pages", title: "Документ Pages", defaultName: "Новый документ",
            fileExtension: "pages", group: .apple, requiredApp: "com.apple.iWork.Pages"
        ),
        DocumentTemplate(
            id: "numbers", title: "Таблица Numbers", defaultName: "Новая таблица",
            fileExtension: "numbers", group: .apple, requiredApp: "com.apple.iWork.Numbers"
        ),
        DocumentTemplate(
            id: "key", title: "Презентация Keynote", defaultName: "Новая презентация",
            fileExtension: "key", group: .apple, requiredApp: "com.apple.iWork.Keynote"
        ),
    ]

    /// Шаблоны, которые есть смысл предлагать на этой машине: пункт остаётся,
    /// если приложение-редактор установлено. Порядок `all` сохраняется — на нём
    /// держится группировка меню.
    public static func available(with apps: some AppLookup) -> [DocumentTemplate] {
        all.filter { template in
            guard let bundleID = template.requiredApp else { return true }
            return apps.isInstalled(bundleID: bundleID)
        }
    }

    /// Папка с заготовками внутри бандла. Промах означал бы, что ресурсы не
    /// подключены в Package.swift, — это ошибка сборки, а не выполнения.
    public static var templatesRoot: URL {
        guard let url = Bundle.module.url(forResource: "Templates", withExtension: nil) else {
            preconditionFailure("Заготовки документов не подключены к PathwayCore")
        }
        return url
    }
}
