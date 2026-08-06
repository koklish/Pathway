import Foundation

/// Элемент файловой системы, отображаемый в списке.
public struct FileItem: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modificationDate: Date?
    /// Дата создания. Опциональна не только из-за быстрого прохода: на части
    /// сетевых файловых систем её нет вовсе, и SMB — как раз такой случай.
    public let creationDate: Date?
    /// false — элемент из быстрого прохода: размер и даты ещё не прочитаны.
    public let metadataLoaded: Bool

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        size: Int64 = 0,
        modificationDate: Date? = nil,
        creationDate: Date? = nil,
        metadataLoaded: Bool = true
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.metadataLoaded = metadataLoaded
    }

    /// Дата для сортировки и показа в колонке «Дата создания».
    ///
    /// Откат на дату изменения, а не пустое значение: на SMB даты создания часто
    /// нет, и без отката целая папка схлопнулась бы в одну группу «без даты»,
    /// где порядок задаёт уже не сортировка, а выдача readdir — список выглядел
    /// бы несортированным вовсе.
    public var effectiveCreationDate: Date? {
        creationDate ?? modificationDate
    }
}
