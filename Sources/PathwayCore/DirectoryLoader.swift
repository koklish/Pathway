import Foundation

/// Читает содержимое папки с метаданными.
public struct DirectoryLoader {
    public init() {}

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
    ]

    public func load(directory: URL, showHidden: Bool = false) throws -> [FileItem] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Self.keys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        )
        let items = contents.map { url -> FileItem in
            let values = try? url.resourceValues(forKeys: Set(Self.keys))
            return FileItem(
                url: url,
                name: url.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: Int64(values?.fileSize ?? 0),
                modificationDate: values?.contentModificationDate
            )
        }
        return items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
