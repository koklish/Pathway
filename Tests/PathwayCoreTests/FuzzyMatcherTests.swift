import Foundation
import Testing

@testable import PathwayCore

@Suite("Нечёткое сопоставление")
struct FuzzyMatcherTests {
    private func score(_ query: String, _ name: String) -> Int? {
        FuzzyMatcher.match(query: query, in: name)?.score
    }

    // MARK: - Порядок выдачи

    @Test("точное совпадение ранжируется выше начала имени, а не наравне")
    func exactBeatsPrefix() throws {
        // Без разницы в баллах список сортировался бы по имени, и точное
        // попадание тонуло бы среди длинных файлов с тем же началом.
        let exact = try #require(score("договор", "договор"))
        let prefix = try #require(score("договор", "договор-АБВ.pdf"))

        #expect(exact > prefix)
    }

    @Test("начало имени ранжируется выше начала слова внутри")
    func prefixBeatsWordBoundary() throws {
        let prefix = try #require(score("дог", "договор.pdf"))
        let inner = try #require(score("дог", "акт-договор.pdf"))

        #expect(prefix > inner)
    }

    @Test("начало слова ранжируется выше подстроки посреди слова")
    func wordBoundaryBeatsSubstring() throws {
        // Граница слова — сильный сигнал намерения: пользователь чаще ищет
        // начало слова, чем середину.
        let boundary = try #require(score("дог", "акт-договор.pdf"))
        let middle = try #require(score("дог", "перезаключдоговор.pdf"))

        #expect(boundary > middle)
    }

    @Test("подстрока ранжируется выше нечёткого совпадения")
    func substringBeatsFuzzy() throws {
        let substring = try #require(score("дгв", "СМСдгвАкт.pdf"))
        let fuzzy = try #require(score("дгв", "ДолГоВечность.txt"))

        #expect(substring > fuzzy)
    }

    @Test("«дгвр» находит «Договор», но ниже прямого запроса")
    func fuzzyFindsButRanksLower() throws {
        // Ради этого и заведён нечёткий поиск — но он не должен перебивать
        // точное совпадение, иначе выдача перестаёт быть предсказуемой.
        let fuzzy = try #require(score("дгвр", "Договор-АБВ.pdf"))
        let direct = try #require(score("договор", "Договор-АБВ.pdf"))

        #expect(direct > fuzzy)
    }

    @Test("совпадение с меньшими разрывами ранжируется выше")
    func fewerGapsRankHigher() throws {
        // Иначе слитное совпадение оценивалось бы наравне с растянутым, и мусор
        // всплывал бы рядом с осмысленным.
        let tight = try #require(score("дгв", "ДГВодка.txt"))
        let loose = try #require(score("дгв", "ДолГоВечность.txt"))

        #expect(tight > loose)
    }

    @Test("совпадение, растянутое на всё имя, отсекается порогом")
    func farFlungMatchIsCutOff() throws {
        // «ДолгоеГулкоеВышивание» формально содержит д-г-в по порядку, но
        // буквы разделены десятком символов: показывать такое — значит топить
        // осмысленные находки в случайных.
        #expect(score("дгв", "ДолгоеГулкоеВышивание.txt") == nil)
    }

    // MARK: - Правила русского языка

    @Test("регистр не влияет на совпадение")
    func ignoresCase() {
        #expect(score("ДОГОВОР", "договор.pdf") != nil)
        #expect(score("договор", "ДОГОВОР.PDF") != nil)
    }

    @Test("е и ё равнозначны в обе стороны")
    func treatsYoAsYe() {
        // В именах файлов «ё» пишут через раз, и поиск «елка» обязан находить
        // «ёлка» — иначе половина файлов недостижима.
        #expect(score("елка", "ёлка.txt") != nil)
        #expect(score("ёлка", "елка.txt") != nil)
        #expect(score("ЁЛКА", "Елка.txt") != nil)
    }

    @Test("имя в NFD находится по запросу в NFC, а не теряется")
    func matchesAcrossUnicodeNormalization() {
        // macOS хранит имена в NFD: «й» = «и» + диакритика. Без нормализации
        // поиск по «й» молча не находил бы ничего — тот же класс ошибок, что
        // канонизация путей в DirectoryLoader.
        let nfd = "Йошкар-Ола.txt".decomposedStringWithCanonicalMapping
        let query = "Йошкар".precomposedStringWithCanonicalMapping

        #expect(score(query, nfd) != nil)
    }

    @Test("запрос в NFD находит имя в NFC")
    func matchesReverseNormalization() {
        let nfc = "Йошкар-Ола.txt".precomposedStringWithCanonicalMapping
        let query = "Йошкар".decomposedStringWithCanonicalMapping

        #expect(score(query, nfc) != nil)
    }

    // MARK: - Что совпадать не должно

    @Test("буквы не по порядку не совпадают")
    func requiresOrder() {
        // Нечёткость — это пропуски, а не перестановки: иначе «ргд» находило бы
        // «Договор», и выдача стала бы необъяснимой.
        #expect(score("ргд", "Договор.pdf") == nil)
    }

    @Test("отсутствующая буква не совпадает")
    func requiresAllCharacters() {
        #expect(score("договорх", "Договор.pdf") == nil)
    }

    @Test("пустой запрос не совпадает ни с чем")
    func emptyQueryMatchesNothing() {
        // Иначе пустое поле поиска вывалило бы весь диск.
        #expect(score("", "Договор.pdf") == nil)
    }

    @Test("слабое нечёткое совпадение отсекается порогом")
    func weakMatchIsCutOff() {
        // Буквы разбросаны по длинному имени — формально совпадение есть, но
        // показывать такое нельзя: запрос из трёх букв иначе найдёт полдиска.
        #expect(score("абв", "Акт большой ведомости за прошлый год.txt") == nil)
    }

    // MARK: - Подсветка

    @Test("возвращает позиции совпавших букв для подсветки")
    func reportsMatchedPositions() throws {
        // Без позиций пользователю неясно, почему файл найден — особенно при
        // нечётком совпадении.
        let match = try #require(FuzzyMatcher.match(query: "дог", in: "договор.pdf"))

        #expect(match.matchedIndices == [0, 1, 2])
    }

    @Test("позиции подсветки указывают на настоящие буквы имени")
    func matchedPositionsPointAtQueryLetters() throws {
        let name = "акт-договор.pdf"
        let match = try #require(FuzzyMatcher.match(query: "дог", in: name))
        let characters = Array(name)
        let matched = String(match.matchedIndices.map { characters[$0] })

        #expect(matched.lowercased() == "дог")
    }

    @Test("позиции подсветки корректны для имени в NFD")
    func matchedPositionsSurviveNormalization() throws {
        // Индексы должны указывать в исходную строку, а не в нормализованную:
        // иначе подсветка съезжала бы на именах с диакритикой.
        let name = "Йошкар.txt".decomposedStringWithCanonicalMapping
        let match = try #require(FuzzyMatcher.match(query: "Йош", in: name))
        let characters = Array(name)

        #expect(match.matchedIndices.allSatisfy { $0 < characters.count })
    }
}
