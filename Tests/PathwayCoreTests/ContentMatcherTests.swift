import Foundation
import Testing

@testable import PathwayCore

@Suite("Сопоставление содержимого")
struct ContentMatcherTests {

    @Test("находит подстроку без учёта регистра")
    func findsIgnoringCase() throws {
        let snippet = try #require(ContentMatcher.match(query: "ромашка", in: "Поставщик ООО РОМАШКА обязуется"))
        #expect(snippet.text.contains("РОМАШКА"))
    }

    @Test("не находит по нечёткому совпадению: ищется подстрока, а не буквы вразбивку")
    func rejectsFuzzyMatch() {
        #expect(ContentMatcher.match(query: "рмшк", in: "ромашка") == nil)
    }

    @Test("фрагмент содержит текст с обеих сторон от совпадения")
    func snippetKeepsContext() throws {
        let text = String(repeating: "а", count: 200) + "ромашка" + String(repeating: "б", count: 200)
        let snippet = try #require(ContentMatcher.match(query: "ромашка", in: text))
        #expect(snippet.text.hasPrefix("…"))
        #expect(snippet.text.hasSuffix("…"))
        #expect(snippet.text.contains("а"))
        #expect(snippet.text.contains("б"))
    }

    @Test("совпадение в начале файла не обрезается слева многоточием")
    func snippetAtStartHasNoLeadingEllipsis() throws {
        let snippet = try #require(ContentMatcher.match(query: "договор", in: "договор поставки от 2024 года"))
        #expect(!snippet.text.hasPrefix("…"))
    }

    @Test("индексы подсветки указывают на совпадение внутри фрагмента, а не внутри исходного текста")
    func indicesAreRelativeToSnippet() throws {
        let text = String(repeating: "а", count: 300) + "ромашка"
        let snippet = try #require(ContentMatcher.match(query: "ромашка", in: text))
        let characters = Array(snippet.text)
        let highlighted = String(snippet.matchedIndices.map { characters[$0] })
        #expect(highlighted == "ромашка")
    }

    @Test("подсвечивается только первое совпадение, даже если их несколько")
    func highlightsFirstMatchOnly() throws {
        let snippet = try #require(ContentMatcher.match(query: "акт", in: "акт и ещё акт"))
        #expect(snippet.matchedIndices == [0, 1, 2])
    }

    @Test("переводы строк в фрагменте заменяются пробелами: строка списка одна")
    func flattensNewlines() throws {
        let snippet = try #require(ContentMatcher.match(query: "второй", in: "первый\nвторой\nтретий"))
        #expect(!snippet.text.contains("\n"))
        let characters = Array(snippet.text)
        #expect(String(snippet.matchedIndices.map { characters[$0] }) == "второй")
    }

    @Test("пустой запрос не даёт совпадений")
    func emptyQueryFindsNothing() {
        #expect(ContentMatcher.match(query: "", in: "любой текст") == nil)
        #expect(ContentMatcher.match(query: "   ", in: "любой текст") == nil)
    }

    @Test("запрос длиннее текста не находится")
    func longerQueryFindsNothing() {
        #expect(ContentMatcher.match(query: "договор поставки", in: "договор") == nil)
    }

    @Test("совпадение длиннее фрагмента обрезается по правой границе")
    func truncatesOverlongMatch() throws {
        let long = String(repeating: "я", count: 400)
        let snippet = try #require(ContentMatcher.match(query: long, in: "начало " + long + " конец"))
        #expect(snippet.text.count <= ContentMatcher.snippetLength + 2)
        // Обрезка не должна оставлять индексы, выходящие за пределы фрагмента:
        // строка выдачи иначе упала бы на выходе за границы массива.
        let characters = Array(snippet.text)
        #expect(snippet.matchedIndices.allSatisfy { $0 >= 0 && $0 < characters.count })
    }
}
