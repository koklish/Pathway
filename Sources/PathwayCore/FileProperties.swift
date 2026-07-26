import Foundation
import UniformTypeIdentifiers

/// Что показывает диалог свойств. Собирается из выделения в момент открытия —
/// снимок, а не ссылка на живую модель: список под листом может смениться,
/// пока лист открыт.
public enum PropertiesSubject: Sendable {
    case single(FileProperties)
    case group(GroupProperties)
}

/// Свойства одного элемента. Строки уже отформатированы в Core — UI их только
/// показывает, как текст errorMessage: смысл рождается здесь, не во вью.
public struct FileProperties: Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    /// «Документ PDF», «Папка», «Приложение» — человеческое имя из UTType.
    public let kind: String
    /// Путь родительской папки, домашняя сокращена до «~».
    public let location: String
    /// Отформатированная дата; nil → UI покажет «—».
    public let created: String?
    public let modified: String?
    /// «Чтение и запись» / «Только чтение».
    public let access: String
    /// Для файла размер известен сразу. Для папки — nil: считается фоном
    /// DirectorySizeCounter, брать его из FileItem нельзя (там 0 у папки).
    public let immediateSize: Int64?
}

/// Свойства группы: сводка. Без имени, дат и прав — для группы они
/// бессмысленны или потребовали бы «разные значения».
public struct GroupProperties: Sendable {
    public let count: Int
    /// Общая папка или «Разные папки».
    public let location: String
    /// Общий тип или «Файлы разных типов».
    public let kinds: String
    /// URL элементов — корни для рекурсивного подсчёта размера.
    public let urls: [URL]
}

public enum PropertiesBuilder {
    public static func subject(for items: [FileItem]) -> PropertiesSubject {
        if items.count == 1 {
            return .single(single(for: items[0]))
        }
        return .group(group(for: items))
    }

    // MARK: - Один элемент

    private static func single(for item: FileItem) -> FileProperties {
        FileProperties(
            url: item.url,
            name: item.name,
            isDirectory: item.isDirectory,
            kind: kind(for: item),
            location: locationLabel(for: item.url),
            created: formattedDate(item.url, key: .creationDateKey),
            modified: formattedDate(item.url, key: .contentModificationDateKey),
            access: accessLabel(for: item.url),
            // Размер папки берётся фоном — здесь nil-заглушка.
            immediateSize: item.isDirectory ? nil : item.size
        )
    }

    // MARK: - Группа

    private static func group(for items: [FileItem]) -> GroupProperties {
        GroupProperties(
            count: items.count,
            location: sharedLocation(of: items),
            kinds: sharedKinds(of: items),
            urls: items.map(\.url)
        )
    }

    /// Общая папка, если у всех элементов один родитель; иначе «Разные папки».
    private static func sharedLocation(of items: [FileItem]) -> String {
        let parents = Set(items.map { $0.url.deletingLastPathComponent().path })
        guard parents.count == 1, let parent = parents.first else { return "Разные папки" }
        return abbreviateHome(parent)
    }

    /// Общий тип, если расширения совпадают; иначе «Файлы разных типов».
    /// Папка среди выделенного сразу делает набор разнородным.
    private static func sharedKinds(of items: [FileItem]) -> String {
        if items.contains(where: \.isDirectory), !items.allSatisfy(\.isDirectory) {
            return "Файлы разных типов"
        }
        let kinds = Set(items.map { kind(for: $0) })
        guard kinds.count == 1, let only = kinds.first else { return "Файлы разных типов" }
        return only
    }

    // MARK: - Общие вычисления

    /// Человеческое имя типа. UTType по расширению даёт localizedDescription
    /// («Документ PDF») — а не грубое «PDF» из колонки списка.
    private static func kind(for item: FileItem) -> String {
        if item.isDirectory {
            return item.url.pathExtension == "app" ? "Приложение" : "Папка"
        }
        let ext = item.url.pathExtension
        if !ext.isEmpty,
           let type = UTType(filenameExtension: ext),
           let description = type.localizedDescription {
            return description.localizedCapitalized
        }
        return ext.isEmpty ? "Документ" : "Документ \(ext.uppercased())"
    }

    private static func locationLabel(for url: URL) -> String {
        abbreviateHome(url.deletingLastPathComponent().path)
    }

    /// Домашнюю папку сокращаем до «~» — как принято показывать пути в macOS.
    private static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private static func accessLabel(for url: URL) -> String {
        FileManager.default.isWritableFile(atPath: url.path)
            ? "Чтение и запись"
            : "Только чтение"
    }

    private static func formattedDate(_ url: URL, key: URLResourceKey) -> String? {
        guard let values = try? url.resourceValues(forKeys: [key]) else { return nil }
        let date: Date?
        switch key {
        case .creationDateKey: date = values.creationDate
        case .contentModificationDateKey: date = values.contentModificationDate
        default: date = nil
        }
        // .long дата + .shortened время: в свойствах место есть, полная дата
        // читается лучше, чем .abbreviated из колонки списка.
        return date?.formatted(date: .long, time: .shortened)
    }
}
