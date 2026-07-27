import Foundation

/// Находка поиска — файл на диске или запись внутри архива.
public struct SearchResult: Identifiable, Hashable, Sendable {
    /// Файл на диске или запись архива. Разделено, потому что открывается это
    /// по-разному: файл — сразу, запись архива — через извлечение.
    public enum Source: Hashable, Sendable {
        case file
        /// Путь записи внутри архива, как он лежит в оглавлении: «2024/акт.pdf».
        case archiveEntry(path: String)
    }

    public var id: String {
        switch source {
        case .file: url.path
        case .archiveEntry(let path): "\(url.path)#\(path)"
        }
    }

    /// Файл на диске: сам найденный файл либо архив, внутри которого запись.
    public let url: URL
    /// Имя для показа — последний компонент пути (записи или файла).
    public let name: String
    public let source: Source
    /// Балл сопоставления; по нему сортируется выдача.
    public let score: Int
    /// Индексы совпавших букв в `name` — для подсветки.
    public let matchedIndices: [Int]
    public let isDirectory: Bool

    public init(
        url: URL,
        name: String,
        source: Source,
        score: Int,
        matchedIndices: [Int] = [],
        isDirectory: Bool = false
    ) {
        self.url = url
        self.name = name
        self.source = source
        self.score = score
        self.matchedIndices = matchedIndices
        self.isDirectory = isDirectory
    }

    public var isInsideArchive: Bool {
        if case .archiveEntry = source { return true }
        return false
    }

    /// Где лежит находка — вторая строка в списке результатов.
    ///
    /// Для записи архива это имя архива и путь внутри него: «Заказы.zip ›
    /// 2024/». Стрелка, а не слэш: иначе граница архива теряется, и путь
    /// читается как обычная папка.
    public func location(relativeTo base: URL) -> String {
        switch source {
        case .file:
            return Self.relativePath(of: url.deletingLastPathComponent(), from: base)
        case .archiveEntry(let path):
            let inner = (path as NSString).deletingLastPathComponent
            let archive = url.lastPathComponent
            return inner.isEmpty ? archive : "\(archive) › \(inner)/"
        }
    }

    /// Путь папки относительно области поиска; «.» превращается в пустую строку.
    private static func relativePath(of directory: URL, from base: URL) -> String {
        let directoryPath = directory.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        guard directoryPath != basePath else { return "" }
        guard directoryPath.hasPrefix(basePath + "/") else { return directoryPath }
        return String(directoryPath.dropFirst(basePath.count + 1)) + "/"
    }
}
