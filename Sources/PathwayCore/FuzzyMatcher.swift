import Foundation

/// Совпадение запроса с именем: балл и позиции совпавших букв.
public struct FuzzyMatch: Equatable, Sendable {
    /// Чем больше, тем выше в выдаче.
    public let score: Int
    /// Индексы совпавших символов **в исходном имени** — для подсветки.
    public let matchedIndices: [Int]

    public init(score: Int, matchedIndices: [Int]) {
        self.score = score
        self.matchedIndices = matchedIndices
    }
}

/// Нечёткое сопоставление запроса с именем файла с ранжированием.
///
/// Возвращает балл, а не «да/нет»: чистый нечёткий поиск даёт мусор, потому
/// что короткий запрос совпадает почти со всем. Порядок выдачи здесь и есть
/// то, что отличает полезный поиск от бесполезного.
///
/// Чистая функция без ввода-вывода — вызывается на каждое имя в каталоге и на
/// каждую запись каждого архива, то есть десятки тысяч раз за поиск.
public enum FuzzyMatcher {

    // MARK: - Баллы

    /// Шкала разрежена намеренно: между классами совпадений лежат сотни, и
    /// никакая сумма бонусов внутри класса не поднимает совпадение в класс выше.
    /// Иначе длинное нечёткое совпадение перебивало бы точное.
    private enum Score {
        static let exact = 1000
        static let prefix = 900
        static let wordBoundary = 800
        static let substring = 700
        static let fuzzy = 300
    }

    /// Ниже этого балла результат не показывается вовсе: запрос из трёх букв
    /// иначе нашёл бы половину диска через разбросанные по имени буквы.
    public static let threshold = 250

    /// Штраф за каждый пропущенный символ между совпавшими буквами. Дороже
    /// бонуса за границу слова: «ДолГоВечность» должно опережать «Дорогой
    /// Гость Вечером», даже если во втором буквы стоят после пробелов.
    private static let gapPenalty = 12

    /// Бонус за букву на границе слова — после разделителя или при смене
    /// регистра. Это сигнал намерения: ищут начало слова, а не середину.
    private static let boundaryBonus = 10

    /// Бонус за совпадение подряд: слитная последовательность осмысленнее
    /// той же длины вразбивку.
    private static let adjacencyBonus = 6

    // MARK: - Сопоставление

    /// Подготовленный запрос.
    ///
    /// Свёртка запроса не зависит от имени, а поиск сопоставляет десятки тысяч
    /// имён с одним запросом. Готовить её на каждое имя — значит повторить
    /// нормализацию пятнадцать тысяч раз за поиск.
    public struct Query: Sendable {
        fileprivate let needle: [Character]

        public init(_ text: String) {
            needle = fold(text)
        }

        public var isEmpty: Bool { needle.isEmpty }
    }

    /// Сопоставляет запрос с именем. `nil` — не совпало или совпало слишком
    /// слабо, чтобы показывать.
    public static func match(query: String, in name: String) -> FuzzyMatch? {
        match(query: Query(query), in: name)
    }

    /// То же, с заранее подготовленным запросом — путь для массового поиска.
    public static func match(query: Query, in name: String) -> FuzzyMatch? {
        let needle = query.needle
        guard !needle.isEmpty else { return nil }
        // Запрос длиннее имени не совпадёт никогда: отсекаем до построения
        // карты индексов, самой дорогой части.
        guard needle.count <= name.count else { return nil }
        // Дешёвый отсев: имя обязано содержать все буквы запроса по порядку.
        // Подавляющее большинство имён отсеиваются здесь, и построение Folded
        // с картой индексов для них не выполняется вовсе — на архиве в 10 000
        // записей это разница между секундой и десятками миллисекунд.
        guard containsInOrder(needle, in: name) else { return nil }

        let haystack = Folded(name)

        guard let result = classify(needle: needle, haystack: haystack) else { return nil }
        guard result.score >= threshold else { return nil }
        return result
    }

    /// Разбирает совпадение по классам — от точного к нечёткому.
    private static func classify(needle: [Character], haystack: Folded) -> FuzzyMatch? {
        let hay = haystack.characters

        if hay == needle {
            return FuzzyMatch(score: Score.exact, matchedIndices: haystack.originalIndices(0..<hay.count))
        }
        if hay.starts(with: needle) {
            return FuzzyMatch(score: Score.prefix, matchedIndices: haystack.originalIndices(0..<needle.count))
        }
        if let start = firstIndex(of: needle, in: hay, wordStartsOf: haystack) {
            return FuzzyMatch(
                score: Score.wordBoundary,
                matchedIndices: haystack.originalIndices(start..<(start + needle.count))
            )
        }
        if let start = firstIndex(of: needle, in: hay, wordStartsOf: nil) {
            return FuzzyMatch(
                score: Score.substring,
                matchedIndices: haystack.originalIndices(start..<(start + needle.count))
            )
        }
        return fuzzy(needle: needle, haystack: haystack)
    }

    /// Ищет подстроку; с переданным `wordStartsOf` — только на границе слова.
    private static func firstIndex(
        of needle: [Character],
        in hay: [Character],
        wordStartsOf haystack: Folded?
    ) -> Int? {
        guard needle.count <= hay.count else { return nil }
        for start in 0...(hay.count - needle.count) {
            if let haystack, !haystack.isWordStart(start) { continue }
            if Array(hay[start..<(start + needle.count)]) == needle { return start }
        }
        return nil
    }

    /// Нечёткое совпадение: буквы запроса идут по порядку, но с пропусками.
    ///
    /// Жадный проход слева направо, а не полный перебор: имён десятки тысяч за
    /// поиск, и экспоненциальный алгоритм подвесил бы интерфейс. Жадность
    /// иногда даёт балл ниже оптимального, но на порядок выдачи это не влияет —
    /// классы совпадений разнесены сотнями очков.
    private static func fuzzy(needle: [Character], haystack: Folded) -> FuzzyMatch? {
        let hay = haystack.characters
        var indices: [Int] = []
        indices.reserveCapacity(needle.count)

        var position = 0
        for character in needle {
            guard let found = hay[position...].firstIndex(of: character) else { return nil }
            indices.append(found)
            position = found + 1
        }

        var score = Score.fuzzy
        for (offset, index) in indices.enumerated() {
            if haystack.isWordStart(index) { score += boundaryBonus }
            guard offset > 0 else { continue }
            let gap = index - indices[offset - 1] - 1
            if gap == 0 { score += adjacencyBonus } else { score -= gap * gapPenalty }
        }

        return FuzzyMatch(score: score, matchedIndices: haystack.originalIndices(indices))
    }

    /// Разделители слов в именах файлов.
    private static let separators: Set<Character> = [" ", "-", "_", ".", "(", ")", "[", "]", ",", "+", "№", "#"]

    // MARK: - Нормализация

    /// Приводит строку к виду для сравнения: NFC, нижний регистр, ё → е.
    private static func fold(_ string: String) -> [Character] {
        string.precomposedStringWithCanonicalMapping.lowercased().map(foldCharacter)
    }

    /// Все буквы запроса встречаются в имени по порядку.
    ///
    /// Проход по исходной строке без нормализации и без массивов: ленивая
    /// свёртка каждого символа на месте. Отвечает «нет» точно, «да» — с
    /// возможной ошибкой в сторону лишнего (NFD-имя, где буква разложена), и
    /// такие случаи доразбирает полный проход.
    private static func containsInOrder(_ needle: [Character], in name: String) -> Bool {
        var index = needle.startIndex
        for character in name {
            guard index < needle.endIndex else { return true }
            for lowered in character.lowercased() where foldCharacter(lowered) == needle[index] {
                index += 1
                break
            }
        }
        return index == needle.endIndex
    }

    /// Свёртка одного символа без создания промежуточных строк.
    ///
    /// Важно для скорости: матчер вызывается на каждое имя каталога и каждую
    /// запись каждого архива. Посимвольный `lowercased()` через String давал
    /// 1,5 мкс на символ — на архиве с длинными именами это секунды.
    private static func foldCharacter(_ character: Character) -> Character {
        // «ё» и «й» — единственные кириллические буквы, у которых NFC-форма
        // составная; после precomposedStringWithCanonicalMapping они уже
        // склеены, здесь остаётся только приравнять ё к е.
        character == "ё" ? "е" : character
    }

    /// Имя, приведённое к виду для сравнения, с картой обратно в исходные индексы.
    ///
    /// Карта нужна из-за нормализации: в NFD «й» занимает два скаляра, и
    /// индексы свёрнутой строки не совпадают с индексами исходной. Без карты
    /// подсветка съезжала бы на именах с диакритикой.
    private struct Folded {
        let characters: [Character]
        private let map: [Int]
        /// Позиции начал слов, посчитанные по **исходной** строке: свёртка
        /// приводит всё к нижнему регистру, и «ГулкоеВышивание» после неё
        /// неотличимо от сплошного слова.
        private let wordStarts: Set<Int>

        init(_ original: String) {
            // Нормализация всей строки разом, а не посимвольно: Character в
            // Swift — графемный кластер, поэтому «и» + диакритика склеиваются в
            // «й» и число символов сохраняется. Посимвольный путь создавал
            // String на каждую букву и стоил 1,5 мкс на символ — на архиве с
            // длинными именами это складывалось в секунды.
            let normalized = Array(original.precomposedStringWithCanonicalMapping)

            var characters: [Character] = []
            characters.reserveCapacity(normalized.count)
            var map: [Int] = []
            map.reserveCapacity(normalized.count)
            var wordStarts: Set<Int> = []
            var previous: Character?

            for (index, character) in normalized.enumerated() {
                if Self.startsWord(character, after: previous) { wordStarts.insert(characters.count) }
                // lowercased() на Character возвращает String: у «ß» две буквы
                // в нижнем регистре. Для карты индексов это учтено — каждый
                // полученный символ ссылается на исходный кластер.
                for lowered in character.lowercased() {
                    characters.append(foldCharacter(lowered))
                    map.append(index)
                }
                previous = character
            }

            self.characters = characters
            self.map = map
            self.wordStarts = wordStarts
        }

        func isWordStart(_ index: Int) -> Bool { wordStarts.contains(index) }

        /// Символ начинает слово: стоит первым, идёт после разделителя или
        /// заглавный после строчной — «актДоговор» тоже два слова.
        private static func startsWord(_ character: Character, after previous: Character?) -> Bool {
            guard let previous else { return true }
            if separators.contains(previous) { return true }
            return character.isUppercase && previous.isLowercase
        }

        func originalIndices(_ range: Range<Int>) -> [Int] {
            originalIndices(Array(range))
        }

        /// Индексы в исходной строке, без повторов: один графемный кластер мог
        /// дать несколько свёрнутых символов, и подсветка дважды указала бы на
        /// одну букву.
        func originalIndices(_ indices: [Int]) -> [Int] {
            var seen = Set<Int>()
            var result: [Int] = []
            for index in indices where index < map.count {
                let original = map[index]
                if seen.insert(original).inserted { result.append(original) }
            }
            return result
        }
    }
}
