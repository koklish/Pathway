import Foundation

/// Как поступать, если в папке назначения уже есть файл с таким именем.
public enum ConflictResolution: Sendable {
    case keepBoth
    case replace
    case skip
}

public enum FileOperationError: Error, Equatable {
    case invalidName
    case nameAlreadyExists
}

/// Операции с файлами: копирование, перемещение, удаление, переименование.
public struct FileOperations {
    private let fm = FileManager.default

    public init() {}

    // MARK: - Создание и переименование

    public func createFolder(in directory: URL, baseName: String = "Новая папка") throws -> URL {
        let url = uniqueURL(in: directory, name: baseName)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    public func rename(_ url: URL, to newName: String) throws -> URL {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":") else {
            throw FileOperationError.invalidName
        }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        guard target != url else { return url }
        guard !fm.fileExists(atPath: target.path) else {
            throw FileOperationError.nameAlreadyExists
        }
        try fm.moveItem(at: url, to: target)
        return target
    }

    // MARK: - Копирование и перемещение

    public func copy(_ urls: [URL], to destination: URL, onConflict: ConflictResolution = .keepBoth) throws -> [URL] {
        try transfer(urls, to: destination, onConflict: onConflict) { source, target in
            try fm.copyItem(at: source, to: target)
        }
    }

    public func move(_ urls: [URL], to destination: URL, onConflict: ConflictResolution = .keepBoth) throws -> [URL] {
        try transfer(urls, to: destination, onConflict: onConflict) { source, target in
            try fm.moveItem(at: source, to: target)
        }
    }

    /// Общая механика переноса: разрешение конфликтов имён + пропуск исчезнувших файлов.
    private func transfer(
        _ urls: [URL],
        to destination: URL,
        onConflict: ConflictResolution,
        perform: (URL, URL) throws -> Void
    ) throws -> [URL] {
        var results: [URL] = []
        for source in urls {
            guard fm.fileExists(atPath: source.path) else { continue }
            let name = source.lastPathComponent
            var target = destination.appendingPathComponent(name)

            if fm.fileExists(atPath: target.path) {
                switch onConflict {
                case .skip:
                    continue
                case .replace:
                    try fm.removeItem(at: target)
                case .keepBoth:
                    target = uniqueURL(
                        in: destination,
                        name: source.deletingPathExtension().lastPathComponent,
                        extension: source.pathExtension
                    )
                }
            }
            try perform(source, target)
            results.append(target)
        }
        return results
    }

    // MARK: - Удаление

    /// Перемещает объекты в Корзину. Возвращает количество удалённых.
    @discardableResult
    public func moveToTrash(_ urls: [URL]) throws -> Int {
        var count = 0
        for url in urls where fm.fileExists(atPath: url.path) {
            try fm.trashItem(at: url, resultingItemURL: nil)
            count += 1
        }
        return count
    }

    // MARK: - Вспомогательное

    /// Подбирает свободное имя: «Новая папка», «Новая папка 2», «file 2.txt» и так далее.
    private func uniqueURL(in directory: URL, name: String, extension ext: String = "") -> URL {
        func url(for candidate: String) -> URL {
            let base = directory.appendingPathComponent(candidate)
            return ext.isEmpty ? base : base.appendingPathExtension(ext)
        }
        var candidate = name
        var index = 2
        while fm.fileExists(atPath: url(for: candidate).path) {
            candidate = "\(name) \(index)"
            index += 1
        }
        return url(for: candidate)
    }
}
