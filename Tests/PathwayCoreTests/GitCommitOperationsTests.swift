import Foundation
import Testing

@testable import PathwayCore

/// Подставной git для операций коммита: запоминает вызовы и отдаёт ответ,
/// заготовленный на первое слово команды.
private final class CommitFakeGit: GitRunning, @unchecked Sendable {
    private(set) var calls: [[String]] = []
    /// Ответ по первому слову команды: log отдаёт историю, status — файлы.
    var results: [String: String] = [:]
    var failsOn: String?

    func run(_ arguments: [String], in directory: URL?) async throws -> GitResult {
        calls.append(arguments)
        if let failsOn, arguments.first == failsOn {
            return GitResult(output: "", error: "не вышло", status: 1)
        }
        return GitResult(output: results[arguments.first ?? ""] ?? "", error: "", status: 0)
    }
}

@Suite("Операции коммита и истории")
struct GitCommitOperationsTests {

    private let repo = URL(fileURLWithPath: "/tmp/Проект")

    private func record(hash: String, subject: String) -> String {
        [hash, "", "i.kogan", "1756400000", "", subject].joined(separator: "\u{1}") + "\u{0}"
    }

    @Test("log запрашивает историю с ограничением и разбирает её")
    func readsLog() async throws {
        let git = CommitFakeGit()
        git.results["log"] = record(hash: "aaa1111", subject: "Версия 1.3.5")
        let service = GitService(git: git)

        let commits = try await service.log(at: repo, limit: 200)

        #expect(commits.count == 1)
        #expect(commits[0].subject == "Версия 1.3.5")
        #expect(git.calls.contains { $0.contains("--max-count=200") })
    }

    @Test("log спрашивает имена удалённых, чтобы отличить серверные ветки")
    func readsRemotesForLog() async throws {
        // Без списка удалённых ветка fork/main считалась бы локальной: отличить
        // её от локальной ветки со слэшем можно только по имени удалённого.
        let git = CommitFakeGit()
        git.results["remote"] = "fork\norigin\n"
        git.results["log"] = [
            "aaa1111", "", "i.kogan", "1756400000", "fork/main", "Правка",
        ].joined(separator: "\u{1}") + "\u{0}"
        let service = GitService(git: git)

        let commits = try await service.log(at: repo, limit: 10)

        #expect(commits[0].refs == [CommitRef(name: "fork/main", kind: .remote)])
    }

    @Test("догрузка истории пропускает уже показанные коммиты")
    func skipsLoadedCommits() async throws {
        let git = CommitFakeGit()
        let service = GitService(git: git)

        _ = try await service.log(at: repo, limit: 200, skip: 200)

        #expect(git.calls.contains { $0.contains("--skip=200") })
    }

    @Test("changes читает статус и отдаёт список файлов")
    func readsChanges() async throws {
        let git = CommitFakeGit()
        git.results["status"] = """
        # branch.head main
        1 .M N... 100644 100644 100644 abc def Sources/A.swift
        ? Sources/B.swift
        """
        let service = GitService(git: git)

        let changes = try await service.changes(at: repo)

        #expect(changes.map(\.path) == ["Sources/A.swift", "Sources/B.swift"])
    }

    @Test("stage добавляет именно указанные пути, а не всё дерево")
    func stagesGivenPaths() async throws {
        let git = CommitFakeGit()
        let service = GitService(git: git)

        try await service.stage(["Sources/A.swift", "Sources/Б.swift"], at: repo)

        // Явные пути, а не «add .»: точка забрала бы и файлы, галочки с которых
        // человек снял.
        #expect(git.calls[0] == ["add", "--", "Sources/A.swift", "Sources/Б.swift"])
    }

    @Test("unstage убирает пути из индекса, не трогая рабочее дерево")
    func unstagesGivenPaths() async throws {
        let git = CommitFakeGit()
        let service = GitService(git: git)

        try await service.unstage(["Sources/A.swift"], at: repo)

        // reset, а не restore --staged: у последнего в старых версиях git
        // другое поведение с новыми файлами.
        #expect(git.calls[0] == ["reset", "--quiet", "HEAD", "--", "Sources/A.swift"])
    }

    @Test("stage с пустым списком git не запускает")
    func emptyStageRunsNothing() async throws {
        let git = CommitFakeGit()
        let service = GitService(git: git)

        try await service.stage([], at: repo)
        try await service.unstage([], at: repo)

        // «git add --» без путей — ошибка, а не пустая операция.
        #expect(git.calls.isEmpty)
    }

    @Test("commit передаёт сообщение аргументом, а не через редактор")
    func commitsWithMessage() async throws {
        let git = CommitFakeGit()
        let service = GitService(git: git)

        try await service.commit(message: "Панель коммитов", at: repo)

        // -m обязателен: без него git открыл бы редактор, которого в
        // приложении нет, и операция повисла бы до таймаута.
        #expect(git.calls[0] == ["commit", "-m", "Панель коммитов"])
    }

    @Test("сообщение с переносами строк уходит одним аргументом")
    func keepsMultilineMessage() async throws {
        let git = CommitFakeGit()
        let service = GitService(git: git)

        try await service.commit(message: "Заголовок\n\nТело коммита", at: repo)

        #expect(git.calls[0] == ["commit", "-m", "Заголовок\n\nТело коммита"])
    }

    @Test("неудача коммита превращается в ошибку с текстом")
    func commitFailureThrows() async throws {
        let git = CommitFakeGit()
        git.failsOn = "commit"
        let service = GitService(git: git)

        await #expect(throws: GitError.self) {
            try await service.commit(message: "Не выйдет", at: repo)
        }
    }

    @Test("discard возвращает отслеживаемый файл к состоянию HEAD")
    func discardsTrackedFile() async throws {
        let git = CommitFakeGit()
        let service = GitService(git: git)

        try await service.discard(["Sources/A.swift"], untracked: [], at: repo)

        // --staged и рабочее дерево разом: файл мог быть добавлен в индекс, и
        // без --staged откат оставил бы там прежнюю правку.
        #expect(git.calls[0] == ["restore", "--staged", "--worktree", "--", "Sources/A.swift"])
    }

    @Test("discard удаляет неотслеживаемый файл, а не пытается его восстановить")
    func discardsUntrackedByDeleting() async throws {
        // git restore на файле, которого нет в HEAD, падает с ошибкой: такому
        // файлу нечего восстанавливать, его можно только удалить.
        let git = CommitFakeGit()
        let service = GitService(git: git)

        try await service.discard([], untracked: ["Sources/Новый.swift"], at: repo)

        #expect(git.calls[0] == ["clean", "-f", "--", "Sources/Новый.swift"])
    }
}

@Suite("Файлы одного коммита")
struct CommitFilesTests {

    private let repo = URL(fileURLWithPath: "/tmp/Проект")

    @Test("разбирает буквы состояния и пути из git show")
    func parsesNameStatus() {
        let output = "M\tSources/A.swift\nA\tSources/B.swift\nD\tSources/C.swift\n"

        let files = GitChange.parseNameStatus(output)

        #expect(files.map(\.path) == ["Sources/A.swift", "Sources/B.swift", "Sources/C.swift"])
        #expect(files.map(\.status) == [.modified, .added, .deleted])
    }

    @Test("переименование даёт новое имя в пути и прежнее в oldPath")
    func parsesRenameWithScore() {
        // Формат «R100\tстарый\tновый»: буква идёт с процентом схожести, а
        // путей два — старый первым, в отличие от porcelain=v2.
        let output = "R100\tSources/Old.swift\tSources/New.swift\n"

        let files = GitChange.parseNameStatus(output)

        #expect(files[0].path == "Sources/New.swift")
        #expect(files[0].oldPath == "Sources/Old.swift")
        #expect(files[0].status == .renamed)
    }

    @Test("кириллическое имя раскавычивается и здесь")
    func decodesQuotedPath() {
        let output = "M\t\"sub/\\321\\204\\320\\260\\320\\271\\320\\273.txt\"\n"

        let files = GitChange.parseNameStatus(output)

        #expect(files[0].path == "sub/файл.txt")
    }

    @Test("файлы коммита запрашиваются без текста диффа")
    func asksForNamesOnly() async throws {
        let git = CommitFakeGit()
        git.results["show"] = "M\tSources/A.swift\n"
        let service = GitService(git: git)

        _ = try await service.files(of: "a3f91c2", at: repo)

        // --name-status без патча: тело диффа на большом коммите — мегабайты,
        // а панели нужны только имена.
        #expect(git.calls[0] == ["show", "--name-status", "--format=", "a3f91c2"])
    }

}
