import Foundation

/// Запомненное содержимое папки.
struct CachedDirectory {
    let items: [FileItem]
    let loadedAt: Date
}

/// Кэш содержимого папок: возврат в уже открытую папку показывается мгновенно,
/// а свежие данные подгружаются фоном.
///
/// Особенно важен на сетевых дисках, где повторное чтение каталога стоит сотни миллисекунд.
@MainActor
final class DirectoryCache {
    private var storage: [String: CachedDirectory] = [:]
    /// Порядок обращений для вытеснения давно неиспользованных папок.
    private var recentKeys: [String] = []
    private let limit: Int

    init(limit: Int = 64) {
        self.limit = limit
    }

    private func key(_ directory: URL, showHidden: Bool) -> String {
        // Скрытые файлы меняют состав списка, поэтому это разные записи кэша.
        directory.standardizedFileURL.path + (showHidden ? "|hidden" : "")
    }

    func items(for directory: URL, showHidden: Bool) -> [FileItem]? {
        let key = key(directory, showHidden: showHidden)
        guard let entry = storage[key] else { return nil }
        touch(key)
        return entry.items
    }

    func store(_ items: [FileItem], for directory: URL, showHidden: Bool) {
        let key = key(directory, showHidden: showHidden)
        storage[key] = CachedDirectory(items: items, loadedAt: Date())
        touch(key)
        evictIfNeeded()
    }

    /// Сбрасывает запись после файловых операций — список заведомо устарел.
    func invalidate(_ directory: URL) {
        let path = directory.standardizedFileURL.path
        for suffix in ["", "|hidden"] {
            storage.removeValue(forKey: path + suffix)
            recentKeys.removeAll { $0 == path + suffix }
        }
    }

    func invalidateAll() {
        storage.removeAll()
        recentKeys.removeAll()
    }

    private func touch(_ key: String) {
        recentKeys.removeAll { $0 == key }
        recentKeys.append(key)
    }

    private func evictIfNeeded() {
        while recentKeys.count > limit, let oldest = recentKeys.first {
            storage.removeValue(forKey: oldest)
            recentKeys.removeFirst()
        }
    }
}
