import Foundation
import Observation

/// Сохранённый сервер в списке избранного.
public struct ServerBookmark: Identifiable, Equatable, Hashable, Sendable, Codable {
    public var id: String { address }
    /// Адрес в каноническом виде — «smb://nas.local/Общие».
    public let address: String
    public let name: String
    /// Входить гостем, не спрашивая учётные данные.
    public var isGuest: Bool

    public init(address: String, name: String, isGuest: Bool = false) {
        self.address = address
        self.name = name
        self.isGuest = isGuest
    }

    public init(_ server: ServerAddress, isGuest: Bool = false) {
        self.address = server.url.absoluteString
        self.name = server.displayName
        self.isGuest = isGuest
    }

    /// Разобранный адрес закладки. Экранирование снимает сам разбор.
    public var server: ServerAddress? {
        ServerAddress.parse(address)
    }

    // Закладки, сохранённые до появления флага, читаются как «не гость».
    private enum CodingKeys: String, CodingKey {
        case address, name, isGuest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        address = try container.decode(String.self, forKey: .address)
        name = try container.decode(String.self, forKey: .name)
        isGuest = try container.decodeIfPresent(Bool.self, forKey: .isGuest) ?? false
    }
}

/// Список избранных серверов, переживающий перезапуск приложения.
///
/// Хранятся только адреса — пароли живут в Связке ключей, здесь их нет.
@Observable
@MainActor
public final class ServerBookmarks {
    public private(set) var items: [ServerBookmark] = []

    private let defaults: UserDefaults
    private let key = "servers.bookmarks"
    private let limit = 20

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = load()
    }

    /// Добавляет сервер наверх списка. Повторное подключение поднимает существующую запись.
    public func remember(_ server: ServerAddress, isGuest: Bool = false) {
        let bookmark = ServerBookmark(server, isGuest: isGuest)
        items.removeAll { $0.address == bookmark.address }
        items.insert(bookmark, at: 0)
        if items.count > limit { items = Array(items.prefix(limit)) }
        save()
    }

    public func remove(_ bookmark: ServerBookmark) {
        items.removeAll { $0.address == bookmark.address }
        save()
    }

    public func remove(_ server: ServerAddress) {
        items.removeAll { $0.address == server.url.absoluteString }
        save()
    }

    public func bookmark(for server: ServerAddress) -> ServerBookmark? {
        items.first { $0.address == server.url.absoluteString }
    }

    /// Меняет способ входа у сохранённой закладки, не трогая её место в списке.
    public func setGuest(_ isGuest: Bool, for server: ServerAddress) {
        guard let index = items.firstIndex(where: { $0.address == server.url.absoluteString }) else { return }
        items[index].isGuest = isGuest
        save()
    }

    /// Заменяет адрес закладки, сохраняя её позицию.
    public func replace(_ server: ServerAddress, with updated: ServerAddress, isGuest: Bool) {
        let replacement = ServerBookmark(updated, isGuest: isGuest)
        guard let index = items.firstIndex(where: { $0.address == server.url.absoluteString }) else {
            remember(updated, isGuest: isGuest)
            return
        }
        // Новый адрес мог уже быть в списке — тогда старая запись просто исчезает.
        items.removeAll { $0.address == replacement.address }
        items.insert(replacement, at: min(index, items.count))
        save()
    }

    private func load() -> [ServerBookmark] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ServerBookmark].self, from: data)
        else { return [] }
        return decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
    }
}
