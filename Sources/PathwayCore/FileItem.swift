import Foundation

/// Элемент файловой системы, отображаемый в списке.
public struct FileItem: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modificationDate: Date?
    /// false — элемент из быстрого прохода: размер и дата ещё не прочитаны.
    public let metadataLoaded: Bool
    /// Ветка, если папка является репозиторием git; nil — не репозиторий.
    ///
    /// Поле элемента, а не отдельный словарь «путь → ветка» в модели: иначе
    /// сортировка по колонке заглядывала бы в два источника, а DirectoryCache
    /// пришлось бы учить хранить второй набор данных параллельно основному.
    /// Кэш хранит готовые FileItem — так ветка попадает в него даром.
    public let branch: String?

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        size: Int64 = 0,
        modificationDate: Date? = nil,
        metadataLoaded: Bool = true,
        branch: String? = nil
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.metadataLoaded = metadataLoaded
        self.branch = branch
    }
}
