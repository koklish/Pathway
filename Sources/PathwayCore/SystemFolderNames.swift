import Foundation

/// Русские имена стандартных папок macOS — то, что Finder показывает вместо
/// английских имён на диске: «Рабочий стол» вместо Desktop, «Документы» вместо Documents.
///
/// Словарь, а не `FileManager.displayName`: системный вызов стоит 0.3–1.2 мс на папку
/// (88 мс на 75 элементов домашней папки), а зовётся он на каждый элемент списка —
/// каталог из 500 файлов обошёлся бы в 150–600 мс поверх 0.7 мс быстрого прохода,
/// на сетевом томе кратно больше. Быстрый проход DirectoryLoader не трогает диск
/// ни разу, и опрос системы за именами сломал бы именно это.
///
/// Цена решения названа явно: папки сторонних программ со своим маркером `.localized`
/// остаются английскими — найти их без обхода диска нельзя.
public enum SystemFolderNames {

    /// Русское имя папки или nil, если она не из стандартного набора.
    ///
    /// Ключом служит полный путь, а не только имя папки: иначе любая пользовательская
    /// папка Documents внутри проекта показалась бы «Документами», а это уже не перевод,
    /// а подмена чужого имени.
    public static func localizedName(for url: URL) -> String? {
        table[url.standardizedFileURL.path]
    }

    /// Имя для показа: русское, если папка стандартная, иначе имя с диска.
    public static func displayName(for url: URL) -> String {
        localizedName(for: url) ?? url.lastPathComponent
    }

    /// То же, но с опросом системы, если папки нет в словаре: так переводятся
    /// ещё и папки сторонних программ со своим маркером `.localized`.
    ///
    /// Только для одиночных путей — заголовок вкладки, хлебные крошки, избранное.
    /// В списке файлов звать нельзя: там это вызов на каждый элемент.
    public static func displayNameAskingSystem(for url: URL) -> String {
        if let known = localizedName(for: url) { return known }
        let system = FileManager.default.displayName(atPath: url.path)
        return system.isEmpty ? url.lastPathComponent : system
    }

    // MARK: - Словарь

    /// Строится один раз: домашний каталог за время работы не меняется.
    private static let table: [String: String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var result = [
            "/Applications": "Программы",
            "/Applications/Utilities": "Утилиты",
            "/Library": "Библиотеки",
            "/System": "Система",
            "/System/Applications": "Программы",
            "/System/Applications/Utilities": "Утилиты",
            "/System/Library": "Библиотеки",
            "/Users": "Пользователи",
        ]
        // Домашние папки перечислены отдельно от системных: у пользователя они свои,
        // и путь к ним известен только в рантайме.
        let userFolders = [
            "Applications": "Программы",
            "Desktop": "Рабочий стол",
            "Documents": "Документы",
            "Downloads": "Загрузки",
            "Library": "Библиотеки",
            "Movies": "Фильмы",
            "Music": "Музыка",
            "Pictures": "Изображения",
            "Public": "Общие",
        ]
        for (name, translation) in userFolders {
            result[home + "/" + name] = translation
        }
        return result
    }()
}
