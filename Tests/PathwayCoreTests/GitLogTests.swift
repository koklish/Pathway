import Foundation
import Testing

@testable import PathwayCore

@Suite("Разбор истории коммитов")
struct GitLogTests {

    /// Строка вывода в формате GitLog.format: поля разделены \u{1}, записи — \u{0}.
    private func line(
        hash: String,
        parents: String = "",
        subject: String,
        author: String = "i.kogan",
        date: TimeInterval = 1_756_400_000,
        refs: String = ""
    ) -> String {
        [hash, parents, author, String(Int(date)), refs, subject]
            .joined(separator: "\u{1}")
    }

    @Test("разбирает хеш, автора, дату и сообщение")
    func parsesFields() {
        let output = line(
            hash: "a3f91c2d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b",
            subject: "Тосты git-операций: результат вместо молчания",
            date: 1_756_400_000
        ) + "\u{0}"

        let commits = GitLog.parse(output)

        #expect(commits.count == 1)
        #expect(commits[0].hash == "a3f91c2d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b")
        #expect(commits[0].shortHash == "a3f91c2")
        #expect(commits[0].author == "i.kogan")
        #expect(commits[0].subject == "Тосты git-операций: результат вместо молчания")
        #expect(commits[0].date == Date(timeIntervalSince1970: 1_756_400_000))
    }

    @Test("сообщение с переносом строки остаётся одним коммитом")
    func multilineSubjectStaysOneCommit() {
        // Записи разделены \u{0}, а не переводом строки, именно ради этого:
        // тело коммита содержит переносы, и разбор по строкам порвал бы его.
        let output = [
            line(hash: "aaa1111", subject: "Первый\nвторая строка тела"),
            line(hash: "bbb2222", subject: "Второй"),
        ].joined(separator: "\u{0}") + "\u{0}"

        let commits = GitLog.parse(output)

        #expect(commits.count == 2)
        #expect(commits[0].subject == "Первый\nвторая строка тела")
        #expect(commits[1].subject == "Второй")
    }

    @Test("коммит с двумя родителями помечен слиянием")
    func detectsMerge() {
        let output = [
            line(hash: "m111", parents: "p111 p222", subject: "Merge branch 'feature/SDLC/14'"),
            line(hash: "p111", parents: "g111", subject: "Обычный"),
        ].joined(separator: "\u{0}") + "\u{0}"

        let commits = GitLog.parse(output)

        #expect(commits[0].isMerge)
        #expect(commits[0].parents == ["p111", "p222"])
        #expect(!commits[1].isMerge)
    }

    @Test("разбирает ветки, теги и HEAD из строки ссылок")
    func parsesRefs() {
        let output = line(
            hash: "aaa1111",
            subject: "Версия 1.3.5",
            refs: "HEAD -> main, origin/main, tag: v1.3.5"
        ) + "\u{0}"

        let commits = GitLog.parse(output)
        let refs = commits[0].refs

        #expect(refs.contains(CommitRef(name: "main", kind: .head)))
        #expect(refs.contains(CommitRef(name: "origin/main", kind: .remote)))
        #expect(refs.contains(CommitRef(name: "v1.3.5", kind: .tag)))
    }

    @Test("голая HEAD без ветки даёт ссылку на отделённую голову")
    func parsesDetachedHead() {
        let output = line(hash: "aaa1111", subject: "Отделённая", refs: "HEAD") + "\u{0}"

        let commits = GitLog.parse(output)

        #expect(commits[0].refs == [CommitRef(name: "HEAD", kind: .head)])
    }

    @Test("локальная ветка отличается от серверной с тем же именем")
    func distinguishesLocalFromRemote() {
        // origin/feature/X содержит слэш ровно так же, как локальная
        // feature/X: различает их только префикс имени удалённого.
        let output = line(
            hash: "aaa1111",
            subject: "Правка",
            refs: "feature/SDLC/14, origin/feature/SDLC/14"
        ) + "\u{0}"

        let commits = GitLog.parse(output)

        #expect(commits[0].refs.contains(CommitRef(name: "feature/SDLC/14", kind: .branch)))
        #expect(commits[0].refs.contains(CommitRef(name: "origin/feature/SDLC/14", kind: .remote)))
    }

    @Test("серверная ветка узнаётся по имени удалённого, а не по слову origin")
    func recognizesNonDefaultRemote() {
        // Удалённый зовётся не только origin: fork, gitlab, upstream —
        // обычные имена. Список приходит снаружи, из git remote.
        let output = line(hash: "aaa1111", subject: "Правка", refs: "fork/main, main") + "\u{0}"

        let commits = GitLog.parse(output, remotes: ["fork"])

        #expect(commits[0].refs.contains(CommitRef(name: "fork/main", kind: .remote)))
        #expect(commits[0].refs.contains(CommitRef(name: "main", kind: .branch)))
    }

    @Test("ветка с именем, начинающимся как имя удалённого, остаётся локальной")
    func doesNotConfuseBranchWithRemotePrefix() {
        // Ветка forkfix/main начинается на «fork», но удалённым не является:
        // сравнение обязано идти по сегменту целиком, а не по префиксу строки.
        let output = line(hash: "aaa1111", subject: "Правка", refs: "forkfix/main") + "\u{0}"

        let commits = GitLog.parse(output, remotes: ["fork"])

        #expect(commits[0].refs == [CommitRef(name: "forkfix/main", kind: .branch)])
    }

    @Test("пустой вывод даёт пустой список, а не одну пустую запись")
    func emptyOutputGivesNothing() {
        #expect(GitLog.parse("").isEmpty)
        #expect(GitLog.parse("\n").isEmpty)
    }

    @Test("строка без нужного числа полей пропускается")
    func skipsMalformedRecord() {
        let output = "мусор\u{0}" + line(hash: "aaa1111", subject: "Целый") + "\u{0}"

        let commits = GitLog.parse(output)

        #expect(commits.count == 1)
        #expect(commits[0].subject == "Целый")
    }
}
