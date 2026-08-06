import Foundation

/// Читает содержимое папки с метаданными.
///
/// Замеры на SMB показали: всё время съедает сам обход каталога (сотни миллисекунд
/// на холодном кэше), а чтение метаданных поверх уже полученного списка почти бесплатно.
/// Поэтому загрузка разделена на два шага — имена показываем сразу, метаданные добираем следом.
public struct DirectoryLoader: Sendable {
    public init() {}

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
    ]

    /// Полная загрузка: имена и метаданные за один проход.
    public func load(directory: URL, showHidden: Bool = false) throws -> [FileItem] {
        let urls = try contents(of: directory, showHidden: showHidden)
        return Self.sortedByName(urls.map(Self.item(for:)))
    }

    /// Быстрый первый проход: только имена и признак папки.
    ///
    /// Тип берётся из поля d_type, которое readdir отдаёт вместе с именем — без отдельного
    /// stat на каждый объект. Ключевое здесь — не трогать диск ни разу: и stat, и
    /// appendingPathComponent на сетевом томе стоят по запросу к серверу на объект,
    /// что на папке с 510 подпапками давало секунды вместо миллисекунд.
    public func loadNames(directory: URL, showHidden: Bool = false) throws -> [FileItem] {
        guard let handle = opendir(directory.path) else {
            // Папка недоступна или исчезла — пусть ошибку сформирует Foundation.
            _ = try contents(of: directory, showHidden: showHidden)
            return []
        }
        defer { closedir(handle) }

        // Готовим префикс один раз — конкатенация строк вместо построения URL от URL.
        let base = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        var items: [FileItem] = []
        while let entry = readdir(handle) {
            var raw = entry.pointee.d_name
            let name = withUnsafePointer(to: &raw) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            guard showHidden || !name.hasPrefix(".") else { continue }

            let type = entry.pointee.d_type
            // DT_UNKNOWN встречается на некоторых файловых системах — там без stat не обойтись.
            let isDirectory = type == DT_DIR
                || (type == DT_UNKNOWN && Self.isDirectoryViaStat(URL(fileURLWithPath: base + name)))

            // Тип передаём явно: иначе URL пойдёт выяснять его на диск, а на сетевом томе
            // это запрос к серверу на каждый объект — 4824 мс против 0.7 мс на 510 подпапках.
            let url = URL(fileURLWithPath: base + name, isDirectory: isDirectory)

            // Точечного имени мало: Finder прячет ещё и файлы с флагом UF_HIDDEN —
            // так помечены, например, временные файлы Word (~$_имя.docx).
            if !showHidden, Self.isHiddenByFlag(url) { continue }

            // Стандартные папки показываются по-русски, как в Finder. Словарь, а не
            // опрос системы: displayName стоил бы сотен миллисекунд на каталог.
            let displayName = isDirectory ? (SystemFolderNames.localizedName(for: url) ?? name) : name

            items.append(FileItem(url: url, name: displayName, isDirectory: isDirectory, metadataLoaded: false))
        }
        return Self.sortedByName(items)
    }

    private static func isDirectoryViaStat(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// Скрыт ли объект флагом UF_HIDDEN.
    ///
    /// lstat — сетевой запрос, поэтому проверяем только имена, похожие на временные файлы
    /// офисных программ: у остальных этот флаг практически не встречается, а платить
    /// за него полным обходом со stat нельзя.
    private static func isHiddenByFlag(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix("~$") || name.hasPrefix("~") else { return false }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(UF_HIDDEN) != 0
    }

    /// Второй проход: размеры и даты для уже показанного списка.
    public func loadMetadata(for items: [FileItem]) -> [FileItem] {
        items.map { item in
            guard !item.metadataLoaded else { return item }
            return Self.item(for: item.url)
        }
    }

    private func contents(of directory: URL, showHidden: Bool) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Self.keys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        )
    }

    private static func item(for url: URL) -> FileItem {
        let values = try? url.resourceValues(forKeys: Set(keys))
        return FileItem(
            url: url,
            name: SystemFolderNames.displayName(for: url),
            isDirectory: values?.isDirectory ?? false,
            size: Int64(values?.fileSize ?? 0),
            modificationDate: values?.contentModificationDate,
            metadataLoaded: true
        )
    }

    static func sortedByName(_ items: [FileItem]) -> [FileItem] {
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
