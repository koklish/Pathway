import Foundation

/// Общий ресурс на сервере — то, что в Windows называют сетевой папкой.
public struct Share: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    /// Описание с сервера; пусто, если оно ничего не добавляет к имени.
    public let comment: String?

    public init(name: String, comment: String? = nil) {
        self.name = name
        self.comment = comment
    }
}

/// Читает список ресурсов сервера.
///
/// Публичного API для перечисления шар в NetFS нет — `EnumerateShares` доступен
/// только плагинам. Поэтому спрашиваем системную утилиту `smbutil`, она есть
/// в каждой macOS.
public enum ShareList {
    /// Разбирает вывод `smbutil view`.
    ///
    /// Формат — колонки, выровненные пробелами:
    ///     Share                    Type    Comments
    ///     Administrative Department Disk   ADepartment
    /// Имя может содержать пробелы, поэтому границей служит слово типа,
    /// а не первый пробел в строке.
    public static func parse(_ output: String) -> [Share] {
        var shares: [Share] = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line)
            // Заголовок, разделитель, итоговая строка и сообщения об ошибках.
            guard !text.hasPrefix("Share"), !text.hasPrefix("-"), !text.hasPrefix("smbutil:"),
                  !text.contains("shares listed")
            else { continue }

            guard let share = parseLine(text) else { continue }
            shares.append(share)
        }

        return shares.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func parseLine(_ line: String) -> Share? {
        // Ищем тип как отдельное слово: имя ресурса от него слева, описание справа.
        guard let range = typeRange(in: line) else { return nil }

        let name = line[line.startIndex..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        // Показываем только диски: IPC$ и принтеры пользователю ни к чему.
        guard line[range] == "Disk" else { return nil }

        let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        // Описание, повторяющее имя, не несёт информации — не показываем его.
        let comment = rest.isEmpty || rest == name ? nil : rest

        return Share(name: name, comment: comment)
    }

    /// Диапазон слова с типом ресурса. Ищем по границам, иначе «Disk» внутри
    /// имени ресурса сошло бы за разделитель.
    private static func typeRange(in line: String) -> Range<String.Index>? {
        for type in ["Disk", "Pipe", "Printer"] {
            var searchStart = line.startIndex
            while let found = line.range(of: type, range: searchStart..<line.endIndex) {
                let beforeIsSpace = found.lowerBound == line.startIndex
                    || line[line.index(before: found.lowerBound)] == " "
                let afterIsSpace = found.upperBound == line.endIndex
                    || line[found.upperBound] == " "
                if beforeIsSpace, afterIsSpace { return found }
                searchStart = found.upperBound
            }
        }
        return nil
    }
}
