import Foundation
import Observation

/// Сохранённый сервер в списке избранного.
public struct ServerBookmark: Identifiable, Equatable, Hashable, Sendable, Codable {
    /// Идентификатор записи: адрес, а у гостевой — адрес с пометкой.
    ///
    /// Логин уже входит в адрес (см. `ServerAddress.user`), поэтому записи разных
    /// учётных записей различаются сами. Гостевой вход — это отсутствие логина, и
    /// его адрес совпадает с адресом обычного входа без учётных данных: без
    /// пометки в идентификаторе две такие записи схлопывались бы в одну.
    ///
    /// Пометка добавляется только гостям — у остальных идентификатор остаётся
    /// строкой адреса, как было до появления поля. Иначе закладки, сохранённые
    /// прежними версиями, осиротели бы после обновления.
    public var id: String { isGuest ? "\(address)|guest" : address }
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
        self.address = server.key
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
/// Хранятся только адреса — пароли живут в `FileCredentialStore`, здесь их нет.
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
    ///
    /// Вытесняется запись с тем же идентификатором, а не с тем же адресом: под
    /// одним адресом теперь живут разные учётные записи и гостевой вход, и
    /// сравнение по адресу стирало бы соседей.
    public func remember(_ server: ServerAddress, isGuest: Bool = false) {
        let bookmark = ServerBookmark(server, isGuest: isGuest)
        items.removeAll { $0.id == bookmark.id }
        items.insert(bookmark, at: 0)
        if items.count > limit { items = Array(items.prefix(limit)) }
        save()
    }

    public func remove(_ bookmark: ServerBookmark) {
        items.removeAll { $0.id == bookmark.id }
        save()
    }

    /// Убирает записи по адресу — все, сколько бы учётных записей на нём ни было.
    ///
    /// Оставлена для случаев, где закладки на руках нет, а есть только адрес:
    /// например, когда сервер отключают по пути из другой части интерфейса.
    /// Там, где запись известна, вызывайте `remove(_ bookmark:)` — иначе
    /// удаление одного логина унесёт с собой соседний.
    public func remove(_ server: ServerAddress) {
        items.removeAll { $0.address == server.key }
        save()
    }

    /// Закладка по адресу. Гостевая находится тоже — она отличается от обычной
    /// только пометкой в идентификаторе, а адрес у них общий.
    public func bookmark(for server: ServerAddress) -> ServerBookmark? {
        items.first { $0.address == server.key }
    }

    /// Меняет способ входа у сохранённой закладки, не трогая её место в списке.
    ///
    /// Смена гостевого флага меняет идентификатор записи, поэтому проверяется
    /// столкновение: обычный вход, ставший гостевым там, где гостевая запись уже
    /// есть, дал бы в списке два одинаковых идентификатора.
    public func setGuest(_ isGuest: Bool, for server: ServerAddress) {
        guard let index = items.firstIndex(where: { $0.address == server.key }) else { return }
        guard items[index].isGuest != isGuest else { return }
        items[index].isGuest = isGuest
        // Запись с новым идентификатором могла уже существовать: у адреса есть и
        // обычный вход, и гостевой. Прежняя уступает место изменённой, иначе в
        // списке оказались бы две записи с одним идентификатором.
        let changed = items[index]
        items.removeAll { $0.id == changed.id && $0 != changed }
        save()
    }

    /// Заменяет адрес закладки, сохраняя её позицию.
    public func replace(_ server: ServerAddress, with updated: ServerAddress, isGuest: Bool) {
        let replacement = ServerBookmark(updated, isGuest: isGuest)
        guard let index = items.firstIndex(where: { $0.address == server.key }) else {
            remember(updated, isGuest: isGuest)
            return
        }
        // Убираем и заменяемую запись, и возможного двойника по новому адресу:
        // цель могла уже быть в списке. Заменяемая ищется по своему адресу —
        // при смене учётной записи адрес меняется, и по новому идентификатору
        // она бы не нашлась, оставшись в списке рядом с заменой.
        let replaced = items[index]
        items.removeAll { $0.id == replacement.id || $0.id == replaced.id }
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
