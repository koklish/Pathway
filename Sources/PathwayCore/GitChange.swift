import Foundation

/// Изменённый файл в рабочем дереве.
public struct GitChange: Equatable, Sendable, Identifiable {
    /// Что случилось с файлом.
    ///
    /// Буква в интерфейсе рисуется вместе с цветом: различение по одному
    /// оттенку отсекает тех, кто его не видит, — то же правило, что у точки
    /// «есть изменения» в чипе ветки.
    public enum Status: Sendable, Equatable {
        case modified
        case added
        case deleted
        case renamed
        case untracked
        /// Конфликт слияния. Отдельно от modified: закоммитить его как обычную
        /// правку нельзя, и панель обязана это показать, а не предлагать галочку.
        case conflicted

        /// Буква для колонки статуса.
        public var letter: String {
            switch self {
            case .modified: "M"
            case .added: "A"
            case .deleted: "D"
            case .renamed: "R"
            case .untracked: "?"
            case .conflicted: "!"
            }
        }
    }

    public var id: String { path }
    /// Путь от корня репозитория.
    public let path: String
    /// Прежний путь у переименованного файла; nil у остальных.
    public let oldPath: String?
    public let status: Status
    /// Правки попадут в коммит: файл добавлен в индекс.
    public let isStaged: Bool
    /// В индексе часть правок, а часть — только в рабочем дереве.
    ///
    /// Отдельный признак от isStaged: галочка при этом включена (коммит правки
    /// возьмёт), но человеку стоит знать, что возьмёт не все.
    public let isPartiallyStaged: Bool

    public var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Папка от корня репозитория; пустая строка — файл лежит в самом корне.
    ///
    /// Пустая, а не «.»: точка в колонке выглядит именем файла, а не его
    /// отсутствием.
    public var directory: String {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return "" }
        return parts.dropLast().joined(separator: "/")
    }

    public init(
        path: String, oldPath: String? = nil, status: Status,
        isStaged: Bool, isPartiallyStaged: Bool = false
    ) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.isStaged = isStaged
        self.isPartiallyStaged = isPartiallyStaged
    }

    /// Разбирает вывод `git status --porcelain=v2`.
    ///
    /// Тот же вызов, что уже читает GitStatus для чипа: разбирать вывод дважды
    /// дешевле, чем запускать git второй раз.
    public static func parse(_ output: String) -> [GitChange] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            // Заголовки «# branch.*» и игнорируемые «!» пропускаем: первые не
            // файлы, вторые git без --ignored не печатает вовсе.
            if line.hasPrefix("1 ") { return parseOrdinary(line) }
            if line.hasPrefix("2 ") { return parseRenamed(line) }
            if line.hasPrefix("u ") { return parseUnmerged(line) }
            if line.hasPrefix("? ") {
                return GitChange(
                    path: unquote(String(line.dropFirst(2))),
                    status: .untracked, isStaged: false
                )
            }
            return nil
        }
    }

    /// Разбирает вывод `git show --name-status`: «M\tпуть», у переименования —
    /// «R100\tстарый\tновый».
    ///
    /// Формат другой, чем у porcelain=v2, и разбирается отдельно: там пара букв
    /// «индекс + дерево», здесь одна буква с процентом схожести, и порядок
    /// путей у переименования обратный.
    public static func parseNameStatus(_ output: String) -> [GitChange] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, let letter = parts[0].first else { return nil }

            let status: Status = switch letter {
            case "A": .added
            case "D": .deleted
            case "R", "C": .renamed
            default: .modified
            }

            // У переименования путей два, и новый идёт вторым — в отличие от
            // porcelain=v2, где первым стоит как раз новый.
            let path = parts.count > 2 ? String(parts[2]) : String(parts[1])
            let oldPath = parts.count > 2 ? unquote(String(parts[1])) : nil

            return GitChange(
                path: unquote(path), oldPath: oldPath, status: status,
                // Коммит уже создан: делить его файлы на отмеченные и нет
                // нечего — в нём все.
                isStaged: true
            )
        }
    }

    /// Запись «1 XY sub mH mI mW hH hI path».
    private static func parseOrdinary(_ line: Substring) -> GitChange? {
        // maxSplits, а не полное разбиение: путь идёт последним и содержит
        // пробелы — разбей строку целиком, имя «файл с пробелами.txt»
        // превратилось бы в три поля.
        let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard parts.count == 9 else { return nil }
        return make(xy: parts[1], path: String(parts[8]), oldPath: nil)
    }

    /// Запись «2 XY sub mH mI mW hH hI score path\toldPath».
    private static func parseRenamed(_ line: Substring) -> GitChange? {
        let parts = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
        guard parts.count == 10 else { return nil }

        // Оба пути в одном поле через табуляцию — это единственное место в
        // формате, где разделителем служит она, а не пробел.
        let paths = parts[9].split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard let new = paths.first else { return nil }
        let old = paths.count > 1 ? unquote(String(paths[1])) : nil

        return make(xy: parts[1], path: String(new), oldPath: old)
    }

    /// Запись «u XY sub m1 m2 m3 mW h1 h2 h3 path» — конфликт слияния.
    private static func parseUnmerged(_ line: Substring) -> GitChange? {
        let parts = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
        guard parts.count == 11 else { return nil }
        return GitChange(
            path: unquote(String(parts[10])),
            status: .conflicted,
            // Конфликт в индекс не добавлен и добавлен быть не может, пока не
            // разрешён: галочка на нём обещала бы работающий коммит.
            isStaged: false
        )
    }

    /// Собирает запись по паре букв XY: X — индекс, Y — рабочее дерево.
    private static func make(xy: Substring, path: String, oldPath: String?) -> GitChange? {
        guard xy.count == 2, let x = xy.first, let y = xy.last else { return nil }

        let stagedPart = x != "."
        let treePart = y != "."
        // Статус берётся из индекса, если там что-то есть: он говорит о том,
        // что уйдёт в коммит, — а именно это и решает человек, глядя на список.
        let letter = stagedPart ? x : y

        let status: Status = switch letter {
        case "A": .added
        case "D": .deleted
        case "R", "C": .renamed
        default: .modified
        }

        return GitChange(
            path: unquote(path),
            oldPath: oldPath,
            status: status,
            isStaged: stagedPart,
            isPartiallyStaged: stagedPart && treePart
        )
    }

    /// Возвращает имя из формы, в которой его печатает git.
    ///
    /// Всё, что вне ASCII, git закавычивает и пишет побайтно в \nnn. Без
    /// раскавычивания русские имена — а в этом проекте они обычны — выглядели
    /// бы как «\321\204\320\260».
    static func unquote(_ text: String) -> String {
        guard text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 else { return text }
        let body = text.dropFirst().dropLast()

        var bytes: [UInt8] = []
        var index = body.startIndex

        while index < body.endIndex {
            guard body[index] == "\\" else {
                // Символ вне escape пишется своими байтами UTF-8: ASCII здесь
                // и есть один байт, но общий путь надёжнее частного случая.
                bytes.append(contentsOf: Array(String(body[index]).utf8))
                index = body.index(after: index)
                continue
            }

            let next = body.index(after: index)
            guard next < body.endIndex else { break }

            switch body[next] {
            case "n": bytes.append(0x0A); index = body.index(after: next)
            case "t": bytes.append(0x09); index = body.index(after: next)
            case "r": bytes.append(0x0D); index = body.index(after: next)
            case "\"", "\\": bytes.append(contentsOf: Array(String(body[next]).utf8)); index = body.index(after: next)
            default:
                // Восьмеричная последовательность ровно из трёх цифр.
                let end = body.index(next, offsetBy: 3, limitedBy: body.endIndex) ?? body.endIndex
                let digits = body[next..<end]
                if digits.count == 3, let value = UInt8(digits, radix: 8) {
                    bytes.append(value)
                    index = end
                } else {
                    bytes.append(contentsOf: Array("\\".utf8))
                    index = next
                }
            }
        }

        // Собранные байты — UTF-8 целиком, а не посимвольно: одна кириллическая
        // буква занимает два байта, и склеивать их по одному нельзя.
        return String(decoding: bytes, as: UTF8.self)
    }
}
