import Foundation
import Testing

@testable import PathwayCore

@Suite("Разбор списка веток")
struct BranchListTests {

    /// Строка вывода в том виде, в каком её отдаёт git.
    private func line(_ ref: String, _ unix: String = "1700000000", symref: String = "") -> String {
        "\(ref)\u{1}\(unix)\u{1}\(symref)"
    }

    @Test("различает локальные и серверные по refs/heads и refs/remotes")
    func splitsLocalAndRemote() {
        let output = [
            line("refs/heads/main"),
            line("refs/remotes/origin/develop"),
        ].joined(separator: "\n")

        let branches = BranchList.parse(output, current: "main")

        #expect(branches.count == 2)
        #expect(branches[0] == Branch(name: "main", isCurrent: true,
                                      date: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(branches[1].name == "develop")
        #expect(branches[1].isRemote)
    }

    @Test("локальная ветка со слэшем не принимается за серверную")
    func slashInLocalNameIsNotRemote() {
        // Ловушка: и feature/SDLC/35, и origin/SDLC/35 содержат слэш, и по
        // нему одну от другой не отличить — различает только полный refname.
        let output = [
            line("refs/heads/feature/SDLC/35"),
            line("refs/remotes/origin/feature/SDLC/42"),
        ].joined(separator: "\n")

        let branches = BranchList.parse(output, current: nil)

        #expect(branches[0] == Branch(name: "feature/SDLC/35",
                                      date: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(branches[1].name == "feature/SDLC/42")
        #expect(branches[1].isRemote)
    }

    @Test("указатель origin/HEAD в список не попадает")
    func skipsSymbolicRef() {
        // В выводе for-each-ref он зовётся refs/remotes/origin, без /HEAD, —
        // отличает его только непустой symref.
        let output = [
            line("refs/remotes/origin", symref: "refs/remotes/origin/main"),
            line("refs/remotes/origin/main"),
        ].joined(separator: "\n")

        let branches = BranchList.parse(output, current: nil)

        #expect(branches.count == 1)
        #expect(branches[0].name == "main")
    }

    @Test("серверная с локальным двойником отсеивается, локальная остаётся")
    func dropsRemoteWithLocalTwin() {
        // Иначе main и origin/main стояли бы двумя строками, и выбор между
        // ними был бы выбором без разницы.
        let output = [
            line("refs/heads/main"),
            line("refs/remotes/origin/main"),
            line("refs/remotes/origin/только-на-сервере"),
        ].joined(separator: "\n")

        let branches = BranchList.parse(output, current: "main")

        #expect(branches.map(\.name) == ["main", "только-на-сервере"])
        #expect(branches[0].isRemote == false)
        #expect(branches[1].isRemote)
    }

    @Test("текущей помечена ветка по имени, а не первая в выводе")
    func marksCurrentByName() {
        let output = [
            line("refs/heads/develop"),
            line("refs/heads/main"),
        ].joined(separator: "\n")

        let branches = BranchList.parse(output, current: "main")

        #expect(branches[0].isCurrent == false)
        #expect(branches[1].isCurrent)
    }

    @Test("порядок сохраняется тот, что дал git, а не алфавитный")
    func keepsGitOrder() {
        // Сортировка по свежести отдана git (--sort=-committerdate): первой
        // должна стоять ветка, где работали вчера, а не «a» из алфавита.
        let output = [
            line("refs/heads/я-свежая", "1700000200"),
            line("refs/heads/а-старая", "1700000100"),
        ].joined(separator: "\n")

        let branches = BranchList.parse(output, current: nil)

        #expect(branches.map(\.name) == ["я-свежая", "а-старая"])
    }

    @Test("вертикальная черта в имени ветки строку не рвёт")
    func pipeInNameSurvives() {
        // git branch 'странная|ветка' создаётся без возражений — потому
        // разделителем и служит управляющий символ, который git запрещает.
        let output = line("refs/heads/странная|ветка")

        let branches = BranchList.parse(output, current: nil)

        #expect(branches.count == 1)
        #expect(branches[0].name == "странная|ветка")
    }

    @Test("пустой вывод даёт пустой список, а не ошибку")
    func emptyOutputGivesEmptyList() {
        #expect(BranchList.parse("", current: nil).isEmpty)
        #expect(BranchList.parse("\n\n", current: nil).isEmpty)
    }

    @Test("нечитаемая дата не выбрасывает ветку из списка")
    func keepsBranchWithoutDate() {
        // Ветка без даты в списке нужнее, чем её отсутствие: выбрать её
        // человек всё равно должен уметь.
        let branches = BranchList.parse(line("refs/heads/main", "мусор"), current: nil)

        #expect(branches.count == 1)
        #expect(branches[0].date == nil)
    }

    @Test("строка неизвестного вида пропускается")
    func skipsUnknownRefs() {
        // refs/tags и прочее: это не ветки, переключаться на них нечем.
        let output = [
            line("refs/tags/v1.0"),
            line("refs/heads/main"),
        ].joined(separator: "\n")

        #expect(BranchList.parse(output, current: nil).map(\.name) == ["main"])
    }
}
