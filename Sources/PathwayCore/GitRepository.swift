import Foundation

/// Является ли папка репозиторием и на какой она ветке.
///
/// Ветка читается из `.git/HEAD`, а не запуском `git`: колонке в списке ветка
/// нужна для каждой строки, и на сотне проектов запуск процесса ценой ~10 мс
/// стоил бы около секунды против единиц миллисекунд на чтении мелкого файла.
public enum GitRepository {

    /// Лежит ли внутри папки служебная запись git.
    ///
    /// Существование, а не тип: у подмодулей и worktree `.git` — файл, а не
    /// папка, и проверка isDirectory отсекла бы их.
    public static func isRepository(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    /// Текущая ветка репозитория; nil — папка не репозиторий или HEAD непонятен.
    public static func branch(at url: URL) -> String? {
        guard let gitDir = gitDirectory(of: url) else { return nil }
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
        else { return nil }
        return parseHead(head)
    }

    /// Отделённая ли это голова: строка — короткий хеш, а не имя ветки.
    ///
    /// Отвечает Core, а не UI: признак выводится из того же разбора HEAD, и
    /// оставь его вью — тот гадал бы по форме строки, повторяя правило
    /// «семь шестнадцатеричных цифр» вторым экземпляром.
    ///
    /// Имя ветки из семи hex-символов (`abcdef1`) git создать позволяет, и
    /// такое имя будет принято за хеш. Цена ошибки — другой значок в чипе;
    /// различать их можно было бы только вторым чтением `.git/refs`, то есть
    /// ещё одним обращением к диску на каждую строку списка.
    public static func isDetached(_ branch: String) -> Bool {
        branch.count == 7 && branch.allSatisfy(\.isHexDigit)
    }

    /// Корень репозитория, внутри которого лежит папка; nil — вне репозитория.
    ///
    /// Подъём останавливается на границе тома, а не идёт до `/`: на сетевом
    /// диске каждый шаг вверх — обращение к SMB, и промах стоил бы заметной
    /// паузы при каждой смене папки.
    public static func root(containing url: URL) -> URL? {
        let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
        var current = url.standardizedFileURL

        while true {
            if isRepository(current) { return current }

            let parent = current.deletingLastPathComponent().standardizedFileURL
            // Достигли корня тома: deletingLastPathComponent от "/" даёт "/".
            guard parent.path != current.path else { return nil }
            if let volume, parent.path.count < volume.standardizedFileURL.path.count { return nil }

            current = parent
        }
    }

    /// Разбирает содержимое HEAD: ссылку на ветку или голый SHA.
    static func parseHead(_ contents: String) -> String? {
        let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref: refs/heads/") {
            let name = String(line.dropFirst("ref: refs/heads/".count))
            return name.isEmpty ? nil : name
        }
        // Detached HEAD: показываем короткий хеш — полный SHA в колонку не влезет
        // и ничего не сообщает глазу.
        let isHex = line.count >= 7 && line.allSatisfy(\.isHexDigit)
        return isHex ? String(line.prefix(7)) : nil
    }

    /// Служебная папка git: сама `.git` либо путь из строки `gitdir:`.
    private static func gitDirectory(of url: URL) -> URL? {
        let git = url.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return git }

        // Подмодуль или worktree: в файле лежит путь к настоящей служебной папке.
        guard let contents = try? String(contentsOf: git, encoding: .utf8) else { return nil }
        let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("gitdir: ") else { return nil }

        let path = String(line.dropFirst("gitdir: ".count))
        // Относительный путь считается от папки репозитория, а не от текущей
        // директории процесса: она к репозиторию отношения не имеет.
        return path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : url.appendingPathComponent(path).standardizedFileURL
    }
}
