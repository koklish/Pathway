import Foundation
import Observation

/// Папка в списке избранного.
public struct Favorite: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let systemImage: String

    public init(url: URL, name: String, systemImage: String) {
        self.url = url
        self.name = name
        self.systemImage = systemImage
    }
}

/// Глобальное состояние приложения: избранное и настройки.
@Observable
@MainActor
public final class AppState {
    public private(set) var favorites: [Favorite] = []
    public var showHiddenFiles: Bool = false

    public init() {
        favorites = Self.defaultFavorites()
    }

    public func addFavorite(_ url: URL) {
        let target = URL(fileURLWithPath: url.path)
        guard !favorites.contains(where: { $0.url == target }) else { return }
        favorites.append(Favorite(url: target, name: target.lastPathComponent, systemImage: "folder"))
    }

    public func removeFavorite(_ url: URL) {
        let target = URL(fileURLWithPath: url.path)
        favorites.removeAll { $0.url == target }
    }

    /// Стандартные папки пользователя с русскими названиями, как в macOS.
    private static func defaultFavorites() -> [Favorite] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let entries: [(String, String, String)] = [
            ("Desktop", "Рабочий стол", "menubar.dock.rectangle"),
            ("Documents", "Документы", "doc"),
            ("Downloads", "Загрузки", "arrow.down.circle"),
            ("Pictures", "Изображения", "photo"),
            ("Music", "Музыка", "music.note"),
            ("Movies", "Видео", "film"),
        ]
        return entries.map { folder, label, icon in
            Favorite(url: home.appendingPathComponent(folder), name: label, systemImage: icon)
        }
    }
}
