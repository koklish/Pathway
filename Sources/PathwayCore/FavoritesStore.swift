import Foundation
import Observation

/// Папка, закреплённая в секции «Избранное».
public struct Favorite: Identifiable, Equatable, Hashable, Sendable, Codable {
    public let id: UUID
    public var url: URL
    public var name: String

    public init(id: UUID = UUID(), url: URL, name: String? = nil) {
        self.id = id
        self.url = url
        self.name = name ?? Self.defaultName(for: url)
    }

    /// Имя так, как его показывает Finder: локализованное, если система его переводит.
    static func defaultName(for url: URL) -> String {
        return SystemFolderNames.displayNameAskingSystem(for: url)
    }
}

/// Пользовательский список избранных папок, переживающий перезапуск приложения.
@Observable
@MainActor
public final class FavoritesStore {
    public private(set) var items: [Favorite] = []

    private let defaults: UserDefaults
    private let key = "favorites.items"
    /// Отдельный флаг нужен, чтобы отличить «первый запуск» от «пользователь всё удалил».
    /// Без него пустой список засевался бы стандартными папками при каждом старте.
    private let seededKey = "favorites.seeded"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.bool(forKey: seededKey) {
            items = load()
            migrateDefaultNames()
        } else {
            items = Self.defaultFavorites()
            defaults.set(true, forKey: seededKey)
            save()
        }
    }

    // MARK: - Изменение списка

    /// Добавляет папку. Уже закреплённая папка повторно не добавляется.
    public func add(_ url: URL, at index: Int? = nil) {
        let standardized = Self.standardize(url)
        guard !contains(standardized) else { return }
        let favorite = Favorite(url: standardized)
        if let index, index >= 0, index <= items.count {
            items.insert(favorite, at: index)
        } else {
            items.append(favorite)
        }
        save()
    }

    public func remove(_ id: Favorite.ID) {
        items.removeAll { $0.id == id }
        save()
    }

    public func remove(url: URL) {
        let standardized = Self.standardize(url)
        items.removeAll { $0.url.path == standardized.path }
        save()
    }

    /// Перестановка с семантикой SwiftUI: destination — позиция в исходном списке,
    /// перед которой встанут перемещаемые элементы. Своя реализация, а не метод
    /// из SwiftUI: PathwayCore не должен зависеть от UI-фреймворка.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moved = source.compactMap { $0 < items.count ? items[$0] : nil }
        guard !moved.isEmpty else { return }
        // Индекс вставки считаем до удаления — иначе он съедет на число
        // выброшенных элементов, лежавших выше по списку.
        let insertion = destination - source.filter { $0 < destination }.count
        var remaining = items
        for index in source.sorted(by: >) where index < remaining.count {
            remaining.remove(at: index)
        }
        remaining.insert(contentsOf: moved, at: max(0, min(insertion, remaining.count)))
        items = remaining
        save()
    }

    public func rename(_ id: Favorite.ID, to name: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items[index].name = trimmed
        save()
    }

    public func contains(_ url: URL) -> Bool {
        let standardized = Self.standardize(url)
        return items.contains { $0.url.path == standardized.path }
    }

    /// Подтягивает перевод к закладкам, сохранённым до его появления.
    ///
    /// Имя закладки — хранимое поле: у тех, кто пользовался приложением раньше,
    /// в UserDefaults лежит английское имя, и defaultName для него уже не зовётся.
    /// Признаком «имя осталось умолчанием» служит совпадение с именем папки на диске —
    /// отдельного флага для этого не нужно, а заданное пользователем имя с ним
    /// не совпадает и потому переживает миграцию.
    private func migrateDefaultNames() {
        var changed = false
        for index in items.indices {
            let item = items[index]
            guard item.name == item.url.lastPathComponent,
                  let localized = SystemFolderNames.localizedName(for: item.url),
                  localized != item.name
            else { continue }
            items[index].name = localized
            changed = true
        }
        // Сохраняем сразу, а не при первом изменении списка: иначе перевод жил бы
        // только в памяти и пересчитывался на каждом запуске.
        if changed { save() }
    }

    // MARK: - Хранение

    /// Пути сравниваются строками, поэтому «/a/b» и «/a/b/» надо привести к одному виду.
    private static func standardize(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path).standardizedFileURL
    }

    private static func defaultFavorites() -> [Favorite] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Desktop", "Documents", "Downloads", "Pictures"]
            .map { Favorite(url: standardize(home.appendingPathComponent($0))) }
    }

    private func load() -> [Favorite] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Favorite].self, from: data)
        else { return [] }
        return decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
    }
}
