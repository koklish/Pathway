import Foundation

/// Как отсортирован список файлов: по какой колонке и в какую сторону.
///
/// Настройка приложения, а не папки: живёт в TabsModel рядом с showHiddenFiles,
/// раздаётся всем вкладкам и сохраняется между запусками. Своё папочное
/// значение потребовало бы хранилища «путь → сортировка» с вопросом, когда его
/// чистить, — и не решало бы жалобу, ради которой всё затевалось.
public struct SortSettings: Equatable, Sendable {
    public let key: String
    public let ascending: Bool

    /// Умолчание — дата изменения, свежие сверху.
    ///
    /// Именно изменения, а не создания: создание файла — тоже изменение, и на
    /// практике даты совпадают, а на SMB даты создания часто нет вовсе.
    /// Отдельное поле ради этого не заводится.
    ///
    /// Свежие сверху — это ascending == false: дата по возрастанию ставит
    /// наверх самые старые файлы, то есть обратное тому, чего ждут от списка.
    public static let defaultKey = "modified"
    public static let defaultAscending = false

    public static let `default` = SortSettings(key: defaultKey, ascending: defaultAscending)

    public init(key: String, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }
}
