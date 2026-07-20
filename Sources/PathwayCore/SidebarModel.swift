import Foundation
import Observation

/// Пункт сайдбара.
public struct SidebarItem: Identifiable, Hashable, Sendable {
    public var id: String { kind.rawValue + url.path }
    public let url: URL
    public let name: String
    public let systemImage: String
    public let kind: Kind
    /// Цвет метки — только для kind == .tag.
    public let tagColor: TagColor?

    public enum Kind: String, Sendable {
        case favorite   // закреплённая папка
        case place      // диск или дерево папок
        case network    // подключение к серверу
        case tag        // цветная метка
    }

    public enum TagColor: String, Sendable, CaseIterable {
        case red, orange, yellow, green, blue, purple, gray

        public var label: String {
            switch self {
            case .red: "Красный"
            case .orange: "Оранжевый"
            case .yellow: "Жёлтый"
            case .green: "Зелёный"
            case .blue: "Синий"
            case .purple: "Фиолетовый"
            case .gray: "Серый"
            }
        }
    }

    public init(url: URL, name: String, systemImage: String, kind: Kind, tagColor: TagColor? = nil) {
        self.url = url
        self.name = name
        self.systemImage = systemImage
        self.kind = kind
        self.tagColor = tagColor
    }
}

/// Секция сайдбара с заголовком.
public struct SidebarSection: Identifiable, Sendable {
    public var id: String { title }
    public let title: String
    public let items: [SidebarItem]
}

/// Содержимое сайдбара и состояние раскрытия дерева.
@Observable
@MainActor
public final class SidebarModel {
    public private(set) var sections: [SidebarSection] = []

    /// Пути хранятся строками без хвостового слэша — URL с ним и без него это разные значения.
    private var expandedPaths: Set<String>

    public init() {
        expandedPaths = ["/"]
        sections = Self.buildSections()
    }

    // MARK: - Раскрытие дерева

    public func isExpanded(_ url: URL) -> Bool {
        expandedPaths.contains(url.path)
    }

    public func toggleExpansion(_ url: URL) {
        if expandedPaths.contains(url.path) {
            expandedPaths.remove(url.path)
        } else {
            expandedPaths.insert(url.path)
        }
    }

    /// Раскрывает все родительские узлы, чтобы папка стала видна в дереве.
    public func reveal(_ url: URL) {
        var current = url.deletingLastPathComponent()
        while current.path != "/" {
            expandedPaths.insert(current.path)
            current = current.deletingLastPathComponent()
        }
        expandedPaths.insert("/")
    }

    // MARK: - Построение секций

    private static func buildSections() -> [SidebarSection] {
        [
            SidebarSection(title: "ИЗБРАННОЕ", items: favorites()),
            SidebarSection(title: "МЕСТА", items: places()),
            SidebarSection(title: "СЕТЬ", items: network()),
            SidebarSection(title: "МЕТКИ", items: tags()),
        ]
    }

    private static func favorites() -> [SidebarItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let entries = [
            ("Desktop", "Рабочий стол"),
            ("Documents", "Документы"),
            ("Downloads", "Загрузки"),
            ("Pictures", "Изображения"),
        ]
        return entries.map { folder, label in
            SidebarItem(
                url: home.appendingPathComponent(folder),
                name: label,
                systemImage: "pin",
                kind: .favorite
            )
        }
    }

    private static func places() -> [SidebarItem] {
        var items = [
            SidebarItem(url: URL(fileURLWithPath: "/"), name: "Этот Mac", systemImage: "folder", kind: .place)
        ]

        let icloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: icloud.path) {
            items.append(SidebarItem(url: icloud, name: "iCloud Drive", systemImage: "folder", kind: .place))
        }

        items.append(contentsOf: externalVolumes())
        return items
    }

    /// Подключённые внешние диски из /Volumes, кроме загрузочного тома.
    private static func externalVolumes() -> [SidebarItem] {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsInternalKey, .volumeNameKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { url in
            guard url.path != "/" else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = values?.volumeName ?? url.lastPathComponent
            return SidebarItem(url: url, name: name, systemImage: "externaldrive", kind: .place)
        }
    }

    private static func network() -> [SidebarItem] {
        [SidebarItem(
            url: URL(fileURLWithPath: "/Network"),
            name: "Подключиться к серверу…",
            systemImage: "plus",
            kind: .network
        )]
    }

    private static func tags() -> [SidebarItem] {
        SidebarItem.TagColor.allCases.map { color in
            SidebarItem(
                url: URL(fileURLWithPath: "/tag/\(color.rawValue)"),
                name: color.label,
                systemImage: "circle.fill",
                kind: .tag,
                tagColor: color
            )
        }
    }
}
