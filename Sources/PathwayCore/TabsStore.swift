import Foundation

/// Состав вкладок, переживающий перезапуск приложения.
///
/// Хранит только пути и активный индекс. История навигации не сохраняется:
/// она обесценивается за время между запусками, а её сериализация потребовала
/// бы вскрыть приватные поля PaneState.
@MainActor
public final class TabsStore {
    private let defaults: UserDefaults
    private let pathsKey = "tabs.paths"
    private let activeKey = "tabs.activeIndex"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(paths: [URL], activeIndex: Int) {
        defaults.set(paths.map(\.path), forKey: pathsKey)
        defaults.set(activeIndex, forKey: activeKey)
    }

    /// Уцелевшие пути и активный индекс. Мёртвые пути отбрасываются молча:
    /// отключённый сетевой том здесь норма, а не ошибка, и алерт «3 вкладки не
    /// восстановлены» на каждом старте после работы с сервером раздражал бы.
    public func restore() -> (paths: [URL], activeIndex: Int) {
        let saved = defaults.stringArray(forKey: pathsKey) ?? []
        let activeIndex = defaults.integer(forKey: activeKey)

        let surviving = saved.filter { Self.isDirectory($0) }
        // Индекс пересчитываем по уцелевшим: отброшенные слева от активной
        // сдвинули бы её, и сохранённый номер указал бы на чужую вкладку.
        let index = saved.prefix(min(max(activeIndex, 0), saved.count))
            .filter { Self.isDirectory($0) }
            .count

        return (surviving.map { URL(fileURLWithPath: $0) }, index)
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
