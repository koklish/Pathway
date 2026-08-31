import Foundation
import Testing

@testable import PathwayCore

/// Отвечает по-разному на разные репозитории: проход по строкам списка должен
/// раскладывать ответы по папкам, а не сваливать один статус на все.
private final class RepoAwareGit: GitRunning, @unchecked Sendable {
    /// Вывод git status по последнему сегменту пути репозитория.
    var outputs: [String: String] = [:]
    private(set) var visited: [String] = []
    /// Репозитории, на которых git падает.
    var failing: Set<String> = []

    func run(_ arguments: [String], in directory: URL?) async throws -> GitResult {
        let name = directory?.lastPathComponent ?? ""
        visited.append(name)
        if failing.contains(name) {
            throw GitError(message: "не сработало")
        }
        return GitResult(output: outputs[name] ?? "", error: "", status: 0)
    }
}

@Suite("Статусы репозиториев в строках списка")
@MainActor
struct RowStatusTests {

    private func makeRepo(in dir: URL, name: String, branch: String = "main") throws -> URL {
        let repo = dir.appendingPathComponent(name)
        let git = repo.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/\(branch)\n"
            .write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        return repo
    }

    private func dirty(_ files: Int, ahead: Int = 0) -> String {
        var lines = ["# branch.head main", "# branch.ab +\(ahead) -0"]
        for index in 0..<files {
            lines.append("1 .M N... 100644 100644 100644 abc def файл\(index).swift")
        }
        return lines.joined(separator: "\n")
    }

    @Test("считает статус каждой папки-репозитория в списке")
    func countsStatusForEachRepository() async throws {
        try await withTempDirAsync { dir in
            _ = try makeRepo(in: dir, name: "Первый")
            _ = try makeRepo(in: dir, name: "Второй")

            let git = RepoAwareGit()
            git.outputs = ["Первый": dirty(3), "Второй": dirty(0)]

            let model = BrowserModel(path: dir, git: GitService(git: git))
            await model.reload()
            await model.refreshRowStatuses()

            #expect(model.rowStatus(for: dir.appendingPathComponent("Первый"))?.changedFiles == 3)
            #expect(model.rowStatus(for: dir.appendingPathComponent("Второй"))?.changedFiles == 0)
        }
    }

    @Test("обычные папки git не тревожат")
    func skipsPlainFolders() async throws {
        try await withTempDirAsync { dir in
            _ = try makeRepo(in: dir, name: "Репозиторий")
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("Просто папка"), withIntermediateDirectories: true)

            let git = RepoAwareGit()
            git.outputs = ["Репозиторий": dirty(1)]

            let model = BrowserModel(path: dir, git: GitService(git: git))
            await model.reload()
            await model.refreshRowStatuses()

            // Запуск процесса на каждую папку стоил бы десятки миллисекунд на
            // строку: обходим только те, где есть .git.
            #expect(git.visited == ["Репозиторий"])
        }
    }

    @Test("упавший git не отменяет статусы остальных репозиториев")
    func failureDoesNotStopOthers() async throws {
        try await withTempDirAsync { dir in
            _ = try makeRepo(in: dir, name: "Сломанный")
            _ = try makeRepo(in: dir, name: "Целый")

            let git = RepoAwareGit()
            git.failing = ["Сломанный"]
            git.outputs = ["Целый": dirty(2)]

            let model = BrowserModel(path: dir, git: GitService(git: git))
            await model.reload()
            await model.refreshRowStatuses()

            #expect(model.rowStatus(for: dir.appendingPathComponent("Целый"))?.changedFiles == 2)
            #expect(model.rowStatus(for: dir.appendingPathComponent("Сломанный")) == nil)
        }
    }

    @Test("смена папки очищает прежние статусы, а не оставляет их чужим строкам")
    func changingFolderClearsStatuses() async throws {
        try await withTempDirAsync { dir in
            let first = dir.appendingPathComponent("Первая")
            let second = dir.appendingPathComponent("Вторая")
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
            _ = try makeRepo(in: first, name: "Проект")

            let git = RepoAwareGit()
            git.outputs = ["Проект": dirty(5)]

            let model = BrowserModel(path: first, git: GitService(git: git))
            await model.reload()
            await model.refreshRowStatuses()
            // От items, а не от склеенного пути: DirectoryLoader канонизирует
            // /var в /private/var, и вручную собранный URL не совпал бы.
            let repo = try #require(model.items.first).url
            #expect(model.rowStatus(for: repo)?.changedFiles == 5)

            model.navigate(to: second)
            await model.waitForLoad()

            // Иначе строка с тем же именем в другой папке унаследовала бы чужой
            // счётчик — и показывала бы его, пока не досчитается свой.
            #expect(model.rowStatus(for: repo) == nil)
        }
    }

    @Test("правка в папке пересчитывает счётчики строк")
    func externalChangeRecountsRows() async throws {
        try await withTempDirAsync { dir in
            _ = try makeRepo(in: dir, name: "Проект")

            let git = RepoAwareGit()
            git.outputs = ["Проект": dirty(4)]

            let model = BrowserModel(path: dir, git: GitService(git: git))
            await model.reload()
            await model.refreshRowStatuses()
            let repo = try #require(model.items.first).url
            #expect(model.rowStatus(for: repo)?.changedFiles == 4)

            // Закоммитили — правок не осталось. Пересчёт обязателен: иначе чип
            // держал бы прежнее число до перехода в другую папку и обратно.
            git.outputs["Проект"] = dirty(0)
            model.refreshAfterReturn()
            await model.waitForLoad()
            await model.refreshRowStatuses()

            #expect(model.rowStatus(for: repo)?.changedFiles == 0)
        }
    }

    @Test("статус берётся из уже посчитанного, а не запускает git повторно")
    func rowStatusDoesNotRunGit() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir, name: "Проект")

            let git = RepoAwareGit()
            git.outputs = ["Проект": dirty(1)]

            let model = BrowserModel(path: dir, git: GitService(git: git))
            await model.reload()
            await model.refreshRowStatuses()

            let before = git.visited.count
            _ = model.rowStatus(for: repo)
            _ = model.rowStatus(for: repo)

            // Чтение вызывается из draw на каждую строку: запусти оно git —
            // прокрутка списка порождала бы процесс на кадр.
            #expect(git.visited.count == before)
        }
    }
}
