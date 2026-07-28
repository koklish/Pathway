import Foundation

/// Фрагмент текста вокруг совпадения — то, что видно в строке выдачи.
public struct ContentSnippet: Hashable, Sendable {
    /// Текст фрагмента, уже с многоточиями по обрезанным краям.
    public let text: String
    /// Индексы совпавших символов **внутри `text`**, а не внутри исходного
    /// файла: подсветке нужны координаты того, что она рисует.
    public let matchedIndices: [Int]

    public init(text: String, matchedIndices: [Int]) {
        self.text = text
        self.matchedIndices = matchedIndices
    }
}

/// Поиск запроса в содержимом файла.
///
/// Подстрока без учёта регистра, а не `FuzzyMatcher`. Нечёткость уместна в
/// имени: строка короткая, опечатка вероятна, ложное совпадение стоит одной
/// лишней строки. В мегабайте текста нечёткое совпадение найдётся **всегда** —
/// выдача выродилась бы в список всех прочитанных файлов. Подстрока — то, что
/// делает grep и поиск в любом редакторе; человек заранее знает, чего ждать.
///
/// Тип чистый: о файлах и диске не знает, поэтому тестируется на строках.
public enum ContentMatcher {

    /// Длина фрагмента в символах. Одна строка списка при принятом кегле —
    /// больше всё равно обрежется многоточием на отрисовке, и обрезала бы уже
    /// вслепую, посреди подсвеченного совпадения.
    public static let snippetLength = 120

    /// Ищет запрос в тексте и возвращает фрагмент вокруг первого совпадения.
    ///
    /// Только первое: остальные совпадения того же файла — это тот же файл, а
    /// строка выдачи одна. Показать все значило бы размножить находку.
    public static func match(query: String, in text: String) -> ContentSnippet? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }

        // Поиск на String.Index, а не на массиве символов: `range(of:)` идёт по
        // хранилищу строки, тогда как Array(text) скопировал бы весь файл в
        // память посимвольно — на 20 МБ это сотни мегабайт впустую.
        guard let found = text.range(
            of: needle, options: [.caseInsensitive, .diacriticInsensitive]
        ) else { return nil }

        let matchLength = text.distance(from: found.lowerBound, to: found.upperBound)
        // Контекст слева — четверть фрагмента: важнее то, что идёт **после**
        // совпадения, а начало нужно лишь чтобы фраза не обрывалась на полуслове.
        let leading = max(0, (snippetLength - matchLength) / 4)

        let start = text.index(found.lowerBound, offsetBy: -leading, limitedBy: text.startIndex)
            ?? text.startIndex
        let end = text.index(start, offsetBy: snippetLength, limitedBy: text.endIndex)
            ?? text.endIndex

        let cut = String(text[start..<end])
        // Переводы строк и табуляции — в пробелы: строка выдачи одна, а без
        // замены многострочный фрагмент растянул бы её по высоте.
        let flattened = cut.map { $0.isNewline || $0 == "\t" ? " " : $0 }

        let offset = text.distance(from: start, to: found.lowerBound)
        // Хвост совпадения мог не поместиться во фрагмент — тогда подсвечиваем
        // ровно то, что видно. Индекс за границей уронил бы отрисовку строки.
        let visible = max(0, min(matchLength, flattened.count - offset))
        let indices = Array(offset..<(offset + visible))

        let prefix = start > text.startIndex ? "…" : ""
        let suffix = end < text.endIndex ? "…" : ""
        // Многоточие слева сдвигает всё содержимое фрагмента на символ вправо.
        let shift = prefix.isEmpty ? 0 : 1

        return ContentSnippet(
            text: prefix + String(flattened) + suffix,
            matchedIndices: indices.map { $0 + shift }
        )
    }
}
