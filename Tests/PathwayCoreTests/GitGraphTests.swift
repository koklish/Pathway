import Foundation
import Testing

@testable import PathwayCore

@Suite("Укладка графа коммитов")
struct GitGraphTests {

    /// Коммит с заданными хешем и родителями. Остальные поля графу не нужны.
    private func commit(_ hash: String, _ parents: String...) -> Commit {
        Commit(
            hash: hash, parents: parents, author: "i.kogan",
            date: Date(timeIntervalSince1970: 0), subject: hash, refs: []
        )
    }

    @Test("линейная история укладывается в одну дорожку")
    func linearHistoryUsesSingleLane() {
        let rows = GitGraph.build([
            commit("a", "b"),
            commit("b", "c"),
            commit("c"),
        ])

        #expect(rows.map(\.lane) == [0, 0, 0])
        #expect(rows.allSatisfy { $0.width == 1 })
    }

    @Test("ветвление разводит коммиты по разным дорожкам")
    func branchOccupiesSecondLane() {
        // m — слияние двух родителей: a остаётся на дорожке 0, b уходит на 1.
        let rows = GitGraph.build([
            commit("m", "a", "b"),
            commit("a", "c"),
            commit("b", "c"),
            commit("c"),
        ])

        #expect(rows[0].lane == 0)  // m
        #expect(rows[1].lane == 0)  // a — первый родитель наследует дорожку
        #expect(rows[2].lane == 1)  // b — второй ушёл вбок
        #expect(rows[3].lane == 0)  // c — обе дорожки сошлись обратно
    }

    @Test("слияние соединяет дорожку-источник с дорожкой родителя")
    func mergeDrawsLinkToSecondParent() {
        let rows = GitGraph.build([
            commit("m", "a", "b"),
            commit("a", "c"),
            commit("b", "c"),
            commit("c"),
        ])

        // Из строки слияния выходят два отрезка: продолжение своей дорожки и
        // ответвление на дорожку второго родителя.
        #expect(rows[0].links.contains(GraphLink(from: 0, to: 0)))
        #expect(rows[0].links.contains(GraphLink(from: 0, to: 1)))
    }

    @Test("сходящиеся дорожки дают отрезок с дорожки потомка на дорожку общего родителя")
    func convergingLanesLinkBack() {
        let rows = GitGraph.build([
            commit("m", "a", "b"),
            commit("a", "c"),
            commit("b", "c"),
            commit("c"),
        ])

        // b лежит на дорожке 1, его родитель c — на дорожке 0: линия обязана
        // сойтись, иначе дорожка 1 обрывалась бы в пустоте.
        #expect(rows[2].links.contains(GraphLink(from: 1, to: 0)))
    }

    @Test("сквозная дорожка продолжается через строку чужого коммита")
    func passingLaneContinuesThroughRow() {
        let rows = GitGraph.build([
            commit("m", "a", "b"),
            commit("a", "c"),
            commit("b", "c"),
            commit("c"),
        ])

        // Строка a (дорожка 0) обязана нести и сквозную линию дорожки 1 —
        // ветка b ещё не закончилась и проходит мимо.
        #expect(rows[1].links.contains(GraphLink(from: 1, to: 1)))
    }

    @Test("ширина строки — число занятых дорожек в ней")
    func widthCountsOccupiedLanes() {
        let rows = GitGraph.build([
            commit("m", "a", "b"),
            commit("a", "c"),
            commit("b", "c"),
            commit("c"),
        ])

        #expect(rows[0].width == 2)  // из m выходят две дорожки
        #expect(rows[1].width == 2)  // a и сквозная b
        #expect(rows[2].width == 2)  // b и сквозная a→c
        #expect(rows[3].width == 1)  // всё сошлось
    }

    @Test("оборванный родитель за пределами выборки не оставляет вечную дорожку")
    func missingParentClosesLane() {
        // Последний коммит выборки ссылается на родителя, которого в списке
        // нет: истории всегда больше, чем показанных 200 строк.
        let rows = GitGraph.build([
            commit("a", "b"),
            commit("b", "нет-в-выборке"),
        ])

        #expect(rows.count == 2)
        #expect(rows[1].lane == 0)
        // Линия уходит вниз за край: обрубить её значило бы нарисовать конец
        // истории там, где её продолжение просто не загружено.
        #expect(rows[1].links.contains(GraphLink(from: 0, to: 0)))
    }

    @Test("первый коммит истории обрывает дорожку")
    func rootCommitEndsLane() {
        let rows = GitGraph.build([
            commit("a", "b"),
            commit("b"),
        ])

        // У b родителей нет вовсе — линия дальше не идёт.
        #expect(rows[1].links.isEmpty)
    }

    @Test("цвет закреплён за дорожкой, а не за строкой")
    func colorFollowsLane() {
        let rows = GitGraph.build([
            commit("m", "a", "b"),
            commit("a", "c"),
            commit("b", "c"),
            commit("c"),
        ])

        // Дорожка 0 всюду одного цвета, дорожка 1 — другого: иначе линия меняла
        // бы цвет по дороге и читалась бы как две разные ветки.
        #expect(rows[0].color == rows[1].color)
        #expect(rows[2].color != rows[0].color)
    }

    @Test("освободившаяся дорожка переиспользуется следующей веткой")
    func lanesAreReused() {
        // Две независимые вилки подряд: вторая обязана занять ту же дорожку 1,
        // что освободила первая, — иначе на длинной истории номера дорожек
        // росли бы бесконечно и граф уехал бы за край панели.
        let rows = GitGraph.build([
            commit("m1", "a", "b"),
            commit("a", "c"),
            commit("b", "c"),
            commit("c", "d", "e"),
            commit("d", "f"),
            commit("e", "f"),
            commit("f"),
        ])

        #expect(rows[5].lane == 1)  // e — снова дорожка 1
        #expect(rows.map(\.width).max() == 2)
    }

    @Test("слияние трёх веток разводит их по трём дорожкам")
    func octopusMergeSpreadsAllParents() {
        // git merge принимает несколько веток разом, и такой коммит имеет три
        // родителя и больше. Учти укладчик только двоих — третья ветка
        // осталась бы без дорожки, а её коммиты повисли бы в пустоте.
        let rows = GitGraph.build([
            commit("m", "a", "b", "c"),
            commit("a", "z"),
            commit("b", "z"),
            commit("c", "z"),
            commit("z"),
        ])

        #expect(rows[0].links.count == 3)
        #expect(Set(rows[0].links.map(\.to)) == [0, 1, 2])
        #expect(rows[1].lane == 0)
        #expect(rows[2].lane == 1)
        #expect(rows[3].lane == 2)
        // Все три сходятся в общего родителя, каждая своим отрезком.
        #expect(rows[4].lane == 0)
    }

    @Test("коммит, которого никто не ждёт, занимает свободную дорожку")
    func unreferencedCommitClaimsLane() {
        // Первый в выборке коммит ветки, чей потомок остался за границей
        // выборки: его хеша нет ни в одной дорожке, и без запасного пути
        // укладка обратилась бы к несуществующему индексу.
        let rows = GitGraph.build([
            commit("сирота", "общий"),
            commit("общий"),
        ])

        #expect(rows[0].lane == 0)
        #expect(rows[1].lane == 0)
    }

    @Test("сошедшаяся дорожка не рвёт линию соседней ветки")
    func convergingLaneKeepsOthersContinuous() {
        // Октопус: на строке b дорожка 1 сходится в дорожку 0, а дорожка 2 ещё
        // идёт к своему коммиту. Освободи укладчик дорожку 1, забыв о сквозной
        // линии дорожки 2, — та исчезла бы между строками b и c, и точка c
        // повисла бы в пустоте, не соединённая ни с чем сверху.
        let rows = GitGraph.build([
            commit("m", "a", "b", "c"),
            commit("a", "z"),
            commit("b", "z"),
            commit("c", "z"),
            commit("z"),
        ])

        // Строка b: дорожка 2 обязана пройти насквозь — её коммит ниже.
        #expect(rows[2].links.contains(GraphLink(from: 2, to: 2)))
    }

    @Test("линия входит в каждую точку сверху")
    func everyDotHasIncomingLine() {
        // Общая проверка связности: у точки на дорожке L обязана быть линия,
        // приходящая в L из строки выше. Иначе коммит нарисован оторванным от
        // истории — граф читался бы как набор не связанных между собой веток.
        let commits = [
            commit("m", "a", "b", "c"),
            commit("a", "z"),
            commit("b", "z"),
            commit("c", "z"),
            commit("z"),
        ]
        let rows = GitGraph.build(commits)

        for index in rows.indices.dropFirst() {
            let incoming = rows[index - 1].links.contains { $0.to == rows[index].lane }
            #expect(incoming, "в строку \(index) не приходит линия сверху")
        }
    }

    @Test("пустая история даёт пустой список строк")
    func emptyHistoryGivesNoRows() {
        #expect(GitGraph.build([]).isEmpty)
    }
}
