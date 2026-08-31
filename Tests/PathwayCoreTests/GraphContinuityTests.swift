import Foundation
import Testing

@testable import PathwayCore

/// Непрерывность линий графа.
///
/// Проверки чисто геометрические и потому живут в Core: рисование ошибку не
/// показывает — на статичном экране разрыв в один пиксель между строками
/// выглядит как задуманный отступ, и заметить его можно только сравнив с
/// референсом. Правила ниже фиксируют, что именно обязано соединяться.
@Suite("Непрерывность графа")
struct GraphContinuityTests {

    private func commit(_ hash: String, _ parents: String...) -> Commit {
        Commit(
            hash: hash, parents: parents, author: "i.kogan",
            date: Date(timeIntervalSince1970: 0), subject: hash, refs: []
        )
    }

    @Test("линия выходит вниз из каждой строки, кроме последней в истории")
    func everyRowExceptRootGoesDown() {
        let rows = GitGraph.build([
            commit("a", "b"),
            commit("b", "c"),
            commit("c"),
        ])

        // Из строк a и b линия обязана уходить вниз, иначе точка следующего
        // коммита висела бы отдельно от предыдущей.
        #expect(!rows[0].links.isEmpty)
        #expect(!rows[1].links.isEmpty)
        // c — первый коммит репозитория: продолжения у истории нет.
        #expect(rows[2].links.isEmpty)
    }

    @Test("выборка, оборванная на границе, оставляет линию уходящей вниз")
    func truncatedHistoryKeepsLineGoing() {
        // Показаны первые 200 коммитов из тысячи: у нижнего родитель есть, он
        // просто ещё не загружен, и обрыв линии соврал бы о конце истории.
        let rows = GitGraph.build([
            commit("a", "b"),
            commit("b", "ещё-не-загружен"),
        ])

        #expect(rows[1].links.contains(GraphLink(from: 0, to: 0)))
    }

    @Test("в точку коммита приходит линия сверху, если ветка началась выше")
    func dotReceivesLineFromAbove() {
        // Строка 2 — коммит ветки на дорожке 1, а началась она в строке 0
        // (слиянии). Верхняя половина её дорожки обязана быть нарисована,
        // иначе точка висит оторванной от ветки, к которой принадлежит, — это
        // и видно как разрыв на дочерних ветках.
        let rows = GitGraph.build([
            commit("m", "a", "b"),
            commit("a", "z"),
            commit("b", "z"),
            commit("z"),
        ])

        #expect(rows[2].lane == 1)
        #expect(rows[2].hasLineAbove, "в точку на дорожке 1 не приходит линия сверху")
    }

    @Test("у первого коммита ветки линии сверху нет")
    func firstCommitOfBranchHasNothingAbove() {
        // Ветка началась этой строкой: выше по её дорожке ничего не было, и
        // отрезок вверх обещал бы продолжение, которого нет.
        let rows = GitGraph.build([
            commit("a", "b"),
            commit("b"),
        ])

        #expect(!rows[0].hasLineAbove)
        #expect(rows[1].hasLineAbove)
    }

    @Test("дорожка, по которой ещё пойдут коммиты, не прерывается")
    func passingLaneNeverBreaks() {
        // Проверка на всю выборку: если дорожка занята выше и занята ниже, она
        // обязана быть нарисована и в промежуточной строке. Разрыв означал бы
        // линию, висящую в воздухе.
        let commits = [
            commit("m", "a", "b"),
            commit("a", "x"),
            commit("x", "z"),
            commit("b", "z"),
            commit("z"),
        ]
        let rows = GitGraph.build(commits)

        for lane in 0...(rows.map(\.width).max() ?? 1) {
            let occupied = rows.indices.filter { index in
                rows[index].lane == lane || rows[index].links.contains { $0.from == lane || $0.to == lane }
            }
            guard let first = occupied.first, let last = occupied.last else { continue }
            for index in first...last {
                let drawn = rows[index].lane == lane
                    || rows[index].links.contains { $0.from == lane || $0.to == lane }
                #expect(drawn, "дорожка \(lane) прервана в строке \(index)")
            }
        }
    }
}
