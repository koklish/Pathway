import Foundation

/// Группа пунктов в подменю «Создать». Порядок значений задаёт порядок групп в
/// меню: сначала то, что работает на любой машине, затем Microsoft.
public enum TemplateGroup: Sendable, Equatable {
    case basic, microsoft
}

/// Из чего складывается содержимое нового документа.
///
/// Содержимое описано значением, а не файлом-заготовкой в ресурсах, потому что
/// ресурсный бандл может не доехать до собранного приложения: `Bundle.module`
/// в этом случае вызывает fatalError и роняет процесс при первом создании
/// документа — именно так приложение и падало у коллег.
public enum DocumentContent: Sendable, Equatable {
    /// Файл нулевой длины. Годится только для простого текста: контейнерные
    /// форматы такой файл считают повреждённым.
    case empty
    /// Готовая строка, записывается как UTF-8.
    case text(String)
    /// Контейнер Office, собирается `OOXMLBuilder` в памяти.
    case ooxml(OOXMLKind)
}

/// Заготовка документа: описание пункта меню и содержимого будущего файла.
public struct DocumentTemplate: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let defaultName: String
    public let fileExtension: String
    public let group: TemplateGroup
    public let content: DocumentContent

    public init(
        id: String,
        title: String,
        defaultName: String,
        fileExtension: String,
        group: TemplateGroup,
        content: DocumentContent
    ) {
        self.id = id
        self.title = title
        self.defaultName = defaultName
        self.fileExtension = fileExtension
        self.group = group
        self.content = content
    }
}

public enum DocumentTemplates {
    /// Полный список — он же состав подменю: наличие Word и Excel не проверяется
    /// намеренно. Документ валиден сам по себе, а меню, зависящее от машины,
    /// объяснить коллеге труднее, чем пункт, открывающийся не тем приложением.
    /// Плата названа явно: на машине без Word созданный .docx откроется тем,
    /// что назначено системой.
    ///
    /// Форматов iWork здесь нет: они закрыты, собрать их кодом нельзя, а хранить
    /// заготовкой в ресурсах — значит вернуть зависимость от бандла, из-за
    /// которой приложение падало. Пять пунктов, работающих всегда, лучше восьми,
    /// три из которых держатся на том, доехал ли ресурс до сборки.
    public static let all: [DocumentTemplate] = [
        DocumentTemplate(
            id: "txt", title: "Текстовый документ", defaultName: "Новый документ",
            fileExtension: "txt", group: .basic, content: .empty
        ),
        // Минимальный RTF: версия, кодировка и таблица шрифтов. TextEdit
        // открывает такой файл пустым документом, как свой собственный.
        DocumentTemplate(
            id: "rtf", title: "Документ RTF", defaultName: "Новый документ",
            fileExtension: "rtf", group: .basic,
            content: .text(#"{\rtf1\ansi\ansicpg1251\deff0{\fonttbl{\f0\fnil Helvetica;}}\f0\fs24 \par}"#)
        ),
        DocumentTemplate(
            id: "docx", title: "Документ Word", defaultName: "Новый документ",
            fileExtension: "docx", group: .microsoft, content: .ooxml(.word)
        ),
        DocumentTemplate(
            id: "xlsx", title: "Книга Excel", defaultName: "Новая книга",
            fileExtension: "xlsx", group: .microsoft, content: .ooxml(.excel)
        ),
        DocumentTemplate(
            id: "pptx", title: "Презентация PowerPoint", defaultName: "Новая презентация",
            fileExtension: "pptx", group: .microsoft, content: .ooxml(.powerPoint)
        ),
    ]
}
