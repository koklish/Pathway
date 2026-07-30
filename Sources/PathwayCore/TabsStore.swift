import Foundation

/// Одна вкладка в сохранённой сессии.
public struct TabRecord: Equatable, Sendable {
    public let path: URL
    public let isPinned: Bool

    public init(path: URL, isPinned: Bool = false) {
        self.path = path
        self.isPinned = isPinned
    }
}

/// Состав вкладок, переживающий перезапуск приложения.
///
/// Хранит пути, признак закрепления и активный индекс. История навигации не
/// сохраняется: она обесценивается за время между запусками, а её сериализация
/// потребовала бы вскрыть приватные поля PaneState.
@MainActor
public final class TabsStore {
    private let defaults: UserDefaults
    /// Старый формат — плоский массив путей, без закрепления. Версии до 1.2.8
    /// писали только его.
    private let legacyPathsKey = "tabs.paths"
    /// Новый формат — массив словарей с путём и флагом.
    private let itemsKey = "tabs.items"
    private let activeKey = "tabs.activeIndex"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(items: [TabRecord], activeIndex: Int) {
        defaults.set(
            items.map { ["path": $0.path.path, "pinned": $0.isPinned] },
            forKey: itemsKey
        )
        defaults.set(activeIndex, forKey: activeKey)
        // Старый ключ убираем: оставленный, он пережил бы откат на прошлую
        // версию и подсунул бы ей вкладки, которых у пользователя уже нет.
        defaults.removeObject(forKey: legacyPathsKey)
    }

    /// Уцелевшие вкладки и активный индекс. Мёртвые пути отбрасываются молча:
    /// отключённый сетевой том здесь норма, а не ошибка, и алерт «3 вкладки не
    /// восстановлены» на каждом старте после работы с сервером раздражал бы.
    public func restore() -> (items: [TabRecord], activeIndex: Int) {
        let saved = savedRecords()
        let activeIndex = defaults.integer(forKey: activeKey)

        let surviving = saved.filter { Self.isDirectory($0.path.path) }
        // Индекс пересчитываем по уцелевшим: отброшенные слева от активной
        // сдвинули бы её, и сохранённый номер указал бы на чужую вкладку.
        let index = saved.prefix(min(max(activeIndex, 0), saved.count))
            .filter { Self.isDirectory($0.path.path) }
            .count

        return (surviving, index)
    }

    /// Читает сессию в любом из двух форматов.
    ///
    /// Форматы разведены по разным ключам, а не уложены в один: UserDefaults
    /// вернул бы [Any], и различать их пришлось бы по типу первого элемента —
    /// на пустом массиве это невозможно в принципе.
    private func savedRecords() -> [TabRecord] {
        if let items = defaults.array(forKey: itemsKey) as? [[String: Any]] {
            return items.compactMap { item in
                guard let path = item["path"] as? String else { return nil }
                return TabRecord(
                    path: URL(fileURLWithPath: path),
                    isPinned: item["pinned"] as? Bool ?? false
                )
            }
        }
        let legacy = defaults.stringArray(forKey: legacyPathsKey) ?? []
        return legacy.map { TabRecord(path: URL(fileURLWithPath: $0)) }
    }

    /// Существует ли каталог по этому пути.
    ///
    /// Для отвалившегося сетевого тома обращение к /Volumes/… может занять
    /// секунды, поэтому спрашиваем только атрибуты точки монтирования, а не
    /// пытаемся прочитать содержимое.
    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
