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
    private let sortKeyKey = "sort.key"
    private let sortAscendingKey = "sort.ascending"
    private let listScaleKey = "list.scale"
    private let columnWidthsKey = "columns.widths"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Сортировка

    public func save(sort: SortSettings) {
        defaults.set(sort.key, forKey: sortKeyKey)
        defaults.set(sort.ascending, forKey: sortAscendingKey)
    }

    /// Сохранённая сортировка или умолчание.
    ///
    /// Направление читается через object(forKey:), а не bool(forKey:): для
    /// отсутствующего ключа bool отдаёт false, что случайно совпадает с нужным
    /// умолчанием, — и «ключа нет» стало бы неотличимо от «пользователь выбрал
    /// по возрастанию». Совпадение сегодняшнее: смени умолчание на true, и
    /// разбор молча возвращал бы не то.
    public func restoreSort() -> SortSettings {
        guard let key = defaults.string(forKey: sortKeyKey) else { return .default }
        let ascending = defaults.object(forKey: sortAscendingKey) as? Bool
            ?? SortSettings.defaultAscending
        return SortSettings(key: key, ascending: ascending)
    }

    // MARK: - Масштаб списка

    public func save(scale: ListScale) {
        defaults.set(scale.rawValue, forKey: listScaleKey)
    }

    /// Сохранённый масштаб или умолчание.
    ///
    /// Читается через object(forKey:), а не integer(forKey:): для отсутствующего
    /// ключа integer отдаёт 0, а 0 — это .compact. Список у не трогавшего
    /// ползунок сжался бы сам собой при первом же запуске новой версии.
    ///
    /// Незнакомое число тоже сводится к умолчанию: сессию мог записать билд с
    /// другим набором ступеней, и rawValue вне шкалы там законен.
    public func restoreScale() -> ListScale {
        guard let raw = defaults.object(forKey: listScaleKey) as? Int else { return .default }
        return ListScale(rawValue: raw) ?? .default
    }

    // MARK: - Ширины колонок

    public func save(columnWidths: ColumnWidths) {
        defaults.set(columnWidths.storage, forKey: columnWidthsKey)
    }

    /// Сохранённые ширины или умолчание.
    ///
    /// Приведение к [String: Double], а не к [String: Any] с разбором каждого
    /// значения: plist мог записать билд с другим форматом, и словарь, где под
    /// ключом лежит строка, обязан целиком свестись к умолчанию, а не отдать
    /// половину колонок. Отдельные негодные числа отсеет уже сам ColumnWidths.
    public func restoreColumnWidths() -> ColumnWidths {
        guard let stored = defaults.dictionary(forKey: columnWidthsKey) as? [String: Double] else {
            return .default
        }
        return ColumnWidths(storage: stored)
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
