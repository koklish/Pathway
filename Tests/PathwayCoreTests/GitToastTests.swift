import Foundation
import Testing

@testable import PathwayCore

/// Отдаёт заранее заготовленные ответы по очереди.
///
/// Общий FakeGit из BrowserGitTests возвращает один результат на все вызовы, а
/// тосту нужен разный `git status` до и после операции — иначе «пришло N
/// коммитов» неоткуда взять.
private final class ScriptedGit: GitRunning, @unchecked Sendable {
    private(set) var calls: [[String]] = []
    /// Ответы по первому слову команды; последний в списке повторяется, когда
    /// очередь исчерпана.
    var responses: [String: [GitResult]] = [:]

    func run(_ arguments: [String], in directory: URL?) async throws -> GitResult {
        calls.append(arguments)
        let key = arguments.first ?? ""
        guard var queue = responses[key], !queue.isEmpty else {
            return GitResult(output: "", error: "", status: 0)
        }
        let result = queue.removeFirst()
        if !queue.isEmpty { responses[key] = queue }
        return result
    }
}

private func status(ahead: Int, behind: Int) -> GitResult {
    GitResult(output: "# branch.head main\n# branch.ab +\(ahead) -\(behind)\n", error: "", status: 0)
}

@Suite("Тосты git-операций")
@MainActor
struct GitToastTests {

    private func makeRepo(in dir: URL) throws -> URL {
        let git = dir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n"
            .write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test("fetch сообщает, сколько коммитов появилось на сервере")
    func fetchReportsNewCommits() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir)
            let git = ScriptedGit()
            // Три ответа по порядку: индикатору при открытии папки, снимку до
            // операции и снимку после — на сервере появились три коммита.
            git.responses["status"] = [
                status(ahead: 0, behind: 0),
                status(ahead: 0, behind: 0),
                status(ahead: 0, behind: 3),
            ]

            let model = BrowserModel(path: repo, git: GitService(git: git))
            await model.refreshRepository()

            model.gitFetch()
            await model.waitForOperation()

            #expect(model.toast?.kind == .success)
            #expect(model.toast?.text == "На сервере 3 новых коммита")
        }
    }

    @Test("fetch без новых коммитов так и говорит, а не молчит")
    func fetchReportsNothingNew() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir)
            let git = ScriptedGit()
            git.responses["status"] = [status(ahead: 0, behind: 0)]

            let model = BrowserModel(path: repo, git: GitService(git: git))
            await model.refreshRepository()

            model.gitFetch()
            await model.waitForOperation()

            // Молчание неотличимо от «операция не запустилась»: человек ждал
            // ответа и должен его получить, даже когда отвечать нечем.
            #expect(model.toast?.text == "Нового нет")
        }
    }

    @Test("pull сообщает, сколько коммитов загрузилось")
    func pullReportsLoadedCommits() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir)
            let git = ScriptedGit()
            git.responses["status"] = [
                status(ahead: 0, behind: 3),
                status(ahead: 0, behind: 3),
                status(ahead: 0, behind: 0),
            ]

            let model = BrowserModel(path: repo, git: GitService(git: git))
            await model.refreshRepository()

            model.gitPull()
            await model.waitForOperation()

            #expect(model.toast?.text == "Загружено 3 коммита")
        }
    }

    @Test("pull на актуальной ветке говорит «Уже актуально», а не «Загружено 0»")
    func pullUpToDate() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir)
            let git = ScriptedGit()
            git.responses["status"] = [status(ahead: 0, behind: 0)]

            let model = BrowserModel(path: repo, git: GitService(git: git))
            await model.refreshRepository()

            model.gitPull()
            await model.waitForOperation()

            #expect(model.toast?.text == "Уже актуально")
        }
    }

    @Test("push сообщает, сколько коммитов ушло")
    func pushReportsSentCommits() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir)
            let git = ScriptedGit()
            git.responses["status"] = [
                status(ahead: 2, behind: 0),
                status(ahead: 2, behind: 0),
                status(ahead: 0, behind: 0),
            ]

            let model = BrowserModel(path: repo, git: GitService(git: git))
            await model.refreshRepository()

            model.gitPush()
            await model.waitForOperation()

            #expect(model.toast?.text == "Отправлено 2 коммита")
        }
    }

    @Test("sync сообщает обе половины одной строкой, а не двумя тостами")
    func syncReportsBothDirections() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir)
            let git = ScriptedGit()
            git.responses["status"] = [
                status(ahead: 2, behind: 3),
                status(ahead: 2, behind: 3),
                status(ahead: 0, behind: 0),
            ]

            let model = BrowserModel(path: repo, git: GitService(git: git))
            await model.refreshRepository()

            model.gitSync()
            await model.waitForOperation()

            // Второй тост вытеснил бы первый, и половина результата пропала бы.
            #expect(model.toast?.text == "Загружено 3, отправлено 2 коммита")
        }
    }

    @Test("неудачный push уходит в тост, а не в модальное окно")
    func failedPushShowsToastNotAlert() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir)
            let git = ScriptedGit()
            git.responses["push"] = [GitResult(output: "", error: "fatal: Authentication failed", status: 128)]

            let model = BrowserModel(path: repo, git: GitService(git: git))
            await model.refreshRepository()

            model.gitPush()
            await model.waitForOperation()

            #expect(model.toast?.kind == .failure)
            #expect(model.toast?.text == "Не удалось отправить изменения")
            // Алерт поверх списка файлов прервал бы работу: сбой обмена с
            // сервером человек исправляет не в диалоге.
            #expect(model.errorMessage == nil)
        }
    }

    @Test("ошибка файловой операции остаётся модальной")
    func fileOperationErrorStaysModal() async throws {
        try await withTempDirAsync { dir in
            let model = BrowserModel(path: dir, git: GitService(git: ScriptedGit()))

            // Имя с «/» недопустимо — операция обязана пожаловаться.
            let file = dir.appendingPathComponent("файл.txt")
            try "текст".write(to: file, atomically: true, encoding: .utf8)
            model.rename(file, to: "не/годится")

            // Тост тут был бы потерей: не переименованный файл остаётся в
            // списке под прежним именем, и пропущенное сообщение означало бы
            // молчаливый отказ.
            #expect(model.errorMessage != nil)
            #expect(model.toast == nil)
        }
    }

    @Test("переключение ветки называет ветку, на которую перешли")
    func switchBranchNamesBranch() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir)
            let model = BrowserModel(path: repo, git: GitService(git: ScriptedGit()))
            await model.refreshRepository()

            model.gitSwitch(to: Branch(name: "develop"))
            await model.waitForOperation()

            #expect(model.toast?.text == "Ветка develop")
        }
    }

    @Test("клонирование сообщает об успехе")
    func cloneReportsSuccess() async throws {
        try await withTempDirAsync { dir in
            let model = BrowserModel(path: dir, git: GitService(git: ScriptedGit()))

            model.gitClone(from: "git@github.com:user/repo.git", name: "Новый")
            await model.waitForOperation()

            #expect(model.toast?.text == "Репозиторий склонирован")
        }
    }

    @Test("числительное согласуется с числом: коммит, коммита, коммитов")
    func pluralAgreesWithNumber() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir)

            // 1, 3, 5 и 11 — все четыре формы русского счёта; 11 отдельно,
            // потому что оканчивается на 1, но требует «коммитов».
            for (behind, expected) in [(1, "Загружено 1 коммит"), (3, "Загружено 3 коммита"),
                                       (5, "Загружено 5 коммитов"), (11, "Загружено 11 коммитов")] {
                let git = ScriptedGit()
                git.responses["status"] = [status(ahead: 0, behind: behind)]
                let model = BrowserModel(path: repo, git: GitService(git: git))
                await model.refreshRepository()

                model.gitPull()
                await model.waitForOperation()

                #expect(model.toast?.text == expected)
            }
        }
    }

    @Test("новый тост вытесняет прежний, а не ждёт его срока")
    func newToastReplacesPrevious() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir)
            let git = ScriptedGit()
            git.responses["status"] = [status(ahead: 0, behind: 0)]

            let model = BrowserModel(path: repo, git: GitService(git: git))
            await model.refreshRepository()

            model.gitFetch()
            await model.waitForOperation()
            let first = model.toast?.id

            model.gitPull()
            await model.waitForOperation()

            // Идентификатор обязан смениться: без этого вью не отличил бы
            // второй результат от всё ещё висящего первого, и человек не
            // понял бы, что операция вообще повторилась.
            #expect(model.toast?.id != first)
        }
    }

    @Test("тост гаснет сам, а ошибка держится дольше успеха")
    func toastHidesItself() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir)
            let model = BrowserModel(path: repo, git: GitService(git: ScriptedGit()))

            // Доли секунды вместо реальных 3 и 8: тест на настоящих сроках
            // стоил бы одиннадцати секунд прогона ради двух проверок. Разрыв
            // между сроками — на порядок: под нагрузкой полного прогона сон
            // просыпается позже заказанного, и на тесных сроках тест начинал
            // падать через раз.
            model.toastDuration = { $0 == .success ? .milliseconds(100) : .seconds(30) }

            model.toast = Toast(.success, "Нового нет")
            try await Task.sleep(for: .milliseconds(600))
            #expect(model.toast == nil)

            model.toast = Toast(.failure, "Не удалось отправить изменения")
            try await Task.sleep(for: .milliseconds(600))
            // Ошибку надо успеть прочитать: текст длиннее, и исчезни он с той
            // же скоростью, человек остался бы с ощущением, что что-то
            // мелькнуло, но что именно — неизвестно.
            #expect(model.toast != nil)
        }
    }

    @Test("закрытый вручную тост не воскресает от прежнего таймера")
    func dismissedToastStaysGone() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir)
            let model = BrowserModel(path: repo, git: GitService(git: ScriptedGit()))
            model.toastDuration = { _ in .milliseconds(100) }

            model.toast = Toast(.success, "Нового нет")
            model.dismissToast()
            #expect(model.toast == nil)

            // Следующий тост живёт заметно дольше первого. Таймер закрытого,
            // не будь он отменён, догорел бы за 50 мс и погасил бы этот —
            // человек увидел бы вспышку вместо сообщения.
            model.toastDuration = { _ in .seconds(30) }
            model.toast = Toast(.success, "Уже актуально")
            try await Task.sleep(for: .milliseconds(600))
            #expect(model.toast != nil)
        }
    }
}
