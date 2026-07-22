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

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        size: Int64 = 0,
        modificationDate: Date? = nil,
        metadataLoaded: Bool = true
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.metadataLoaded = metadataLoaded
    }
}
