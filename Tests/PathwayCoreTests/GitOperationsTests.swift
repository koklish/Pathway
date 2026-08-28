import Foundation
import Testing

@testable import PathwayCore

/// Подставной git: запоминает вызовы и отдаёт заготовленный ответ.
private final class FakeGit: GitRunning, @unchecked Sendable {
    struct Call: Equatable {
        let arguments: [String]
        let directory: URL?
    }

    private(set) var calls: [Call] = []
    var result: GitResult = GitResult(output: "", error: "", status: 0)
    /// Ошибка запуска самого процесса — например, git не установлен.
    var throwsOnRun: (any Error)?
    /// Первое слово команды, на которой фейк вернёт ненулевой код: нужно для
    /// составных операций, где важно, что после неудачи продолжения не было.
    var failsOn: String?

    func run(_ arguments: [String], in directory: URL?) async throws -> GitResult {
        calls.append(Call(arguments: arguments, directory: directory))
        if let throwsOnRun { throw throwsOnRun }
        if let failsOn, arguments.first == failsOn {
            return GitResult(output: "", error: "не вышло", status: 1)
        }
        return result
    }
}

@Suite("Операции над репозиторием")
struct GitOperationsTests {

    private let repo = URL(fileURLWithPath: "/tmp/Проект")

    @Test("fetch, pull и push передают ожидаемые аргументы")
    func passesExpectedArguments() async throws {
        let git = FakeGit()
        let service = GitService(git: git)

        try await service.fetch(at: repo)
        try await service.pull(at: repo)
        try await service.push(at: repo)

        #expect(git.calls[0].arguments == ["fetch", "--prune"])
        // Именно --ff-only: слияние в файловом менеджере может оставить
        // репозиторий в конфликте, разрешать который тут нечем.
        #expect(git.calls[1].arguments == ["pull", "--ff-only"])
        #expect(git.calls[2].arguments == ["push"])
        #expect(git.calls.allSatisfy { $0.directory == repo })
    }

    @Test("sync забирает чужое перед тем, как отдать своё")
    func syncPullsBeforePushing() async throws {
        let git = FakeGit()
        let service = GitService(git: git)

        try await service.sync(at: repo)

        // Порядок, а не просто наличие обеих команд: push до pull сервер
        // отвергнет, если на нём появились чужие коммиты.
        #expect(git.calls.map(\.arguments) == [["pull", "--ff-only"], ["push"]])
        #expect(git.calls.allSatisfy { $0.directory == repo })
    }

    @Test("неудачный pull отменяет push, а не отправляет непроверенное состояние")
    func syncStopsAfterFailedPull() async throws {
        let git = FakeGit()
        git.failsOn = "pull"
        let service = GitService(git: git)

        await #expect(throws: GitError.self) {
            try await service.sync(at: repo)
        }

        // Ровно один вызов: push поверх неудавшегося слияния отправил бы не то
        // состояние, которое человек видел перед нажатием.
        #expect(git.calls.map(\.arguments) == [["pull", "--ff-only"]])
    }

    @Test("переключение зовёт switch, а не checkout")
    func switchesWithSwitchCommand() async throws {
        let git = FakeGit()
        let service = GitService(git: git)

        try await service.switchBranch(to: "feature/SDLC/35", at: repo)

        // Именно switch: у checkout вторая роль — восстановить файл, и
        // опечатка в аргументе там означает потерю правок.
        #expect(git.calls.first?.arguments == ["switch", "feature/SDLC/35"])
        #expect(git.calls.first?.directory == repo)
    }

    @Test("переключение на серверную ветку заводит её с привязкой")
    func switchToRemoteTracksUpstream() async throws {
        let git = FakeGit()
        let service = GitService(git: git)

        try await service.switchToRemote("feature/SDLC/42", at: repo)

        // --track ставит upstream сразу: иначе первый же push потребовал бы
        // «git push -u» в терминале.
        #expect(git.calls.first?.arguments == ["switch", "--track", "origin/feature/SDLC/42"])
    }

    @Test("список веток берётся одним вызовом for-each-ref")
    func listsBranchesInOneCall() async throws {
        let git = FakeGit()
        git.result = GitResult(
            output: "refs/heads/main\u{1}1700000000\u{1}\n",
            error: "", status: 0
        )
        let service = GitService(git: git)

        let branches = try await service.branches(at: repo)

        #expect(git.calls.count == 1)
        #expect(git.calls.first?.arguments.first == "for-each-ref")
        #expect(branches.map(\.name) == ["main"])
    }

@Test("отказ переключения называет конкретные файлы, а не «дерево грязное»")
    func switchConflictNamesFiles() async throws {
        let git = FakeGit()
        // Текст снят с настоящего git: имена идут строками с табуляцией между
        // заголовком error: и строкой Please commit.
        git.result = GitResult(
            output: "",
            error: """
                error: Your local changes to the following files would be overwritten by checkout:
                \ta.txt
                \tSources/PathwayCore/BrowserModel.swift
                Please commit your changes or stash them before you switch branches.
                Aborting
                """,
            status: 1
        )
        let service = GitService(git: git)

        do {
            try await service.switchBranch(to: "main", at: repo)
            Issue.record("ожидалась ошибка")
        } catch let error as GitError {
            #expect(error.message.contains("a.txt"))
            #expect(error.message.contains("Sources/PathwayCore/BrowserModel.swift"))
            // С действием, а не с диагнозом: человеку нужно знать, что делать.
            #expect(error.message.contains("stash"))
            // Сырую жалобу git не показываем: «would be overwritten by
            // checkout» ничего не объясняет тому, кто её видит впервые.
            #expect(!error.message.contains("would be overwritten"))
        }
    }

    @Test("отказ без списка файлов не теряется, а показывает текст git")
    func switchFailureWithoutFileListKeepsText() async throws {
        let git = FakeGit()
        git.result = GitResult(
            output: "",
            error: "fatal: invalid reference: несуществующая",
            status: 128
        )
        let service = GitService(git: git)

        do {
            try await service.switchBranch(to: "несуществующая", at: repo)
            Issue.record("ожидалась ошибка")
        } catch let error as GitError {
            #expect(error.message.contains("invalid reference"))
        }
    }

    @Test("clone запускается в папке назначения и получает адрес репозитория")
    func cloneRunsInDestination() async throws {
        let git = FakeGit()
        let service = GitService(git: git)
        let destination = URL(fileURLWithPath: "/tmp/PhpstormProjects")

        try await service.clone(from: "git@github.com:user/repo.git", into: destination, name: "Проект")

        #expect(git.calls.first?.arguments == ["clone", "git@github.com:user/repo.git", "Проект"])
        #expect(git.calls.first?.directory == destination)
    }

    @Test("clone без имени папки не передаёт пустой аргумент")
    func cloneWithoutNameOmitsArgument() async throws {
        let git = FakeGit()
        let service = GitService(git: git)

        try await service.clone(from: "git@github.com:user/repo.git", into: repo, name: "")

        // Пустая строка аргументом заставила бы git клонировать в папку с
        // пустым именем и упасть с невнятной ошибкой.
        #expect(git.calls.first?.arguments == ["clone", "git@github.com:user/repo.git"])
    }

    @Test("состояние читается одним вызовом status, а не тремя командами")
    func statusIsSingleCall() async throws {
        let git = FakeGit()
        git.result = GitResult(output: "# branch.head main\n# branch.ab +1 -0\n", error: "", status: 0)
        let service = GitService(git: git)

        let status = try await service.status(at: repo)

        #expect(git.calls.count == 1)
        #expect(git.calls[0].arguments == ["status", "--porcelain=v2", "--branch"])
        #expect(status.branch == "main")
        #expect(status.ahead == 1)
    }

    @Test("отказ авторизации объясняет, что делать, а не показывает жалобу git")
    func authFailureExplainsAction() async {
        let git = FakeGit()
        git.result = GitResult(
            output: "",
            error: "fatal: could not read Username for 'https://github.com': terminal prompts disabled",
            status: 128
        )
        let service = GitService(git: git)

        await #expect(throws: GitError.self) { try await service.push(at: repo) }
        do {
            try await service.push(at: repo)
        } catch let error as GitError {
            #expect(error.message.contains("Требуется авторизация"))
            // Сырой текст git человеку ничего не говорит: «terminal prompts
            // disabled» выглядит как поломка приложения, а не как отсутствие
            // сохранённых учётных данных.
            #expect(!error.message.contains("terminal prompts disabled"))
        } catch {
            Issue.record("ожидалась GitError")
        }
    }

    @Test("отказ по ключу SSH тоже объясняется, а не подаётся как сбой")
    func sshFailureExplainsAction() async throws {
        let git = FakeGit()
        git.result = GitResult(
            output: "",
            error: "git@github.com: Permission denied (publickey).",
            status: 128
        )
        let service = GitService(git: git)

        do {
            try await service.push(at: repo)
            Issue.record("ожидалась ошибка")
        } catch let error as GitError {
            #expect(error.message.contains("Требуется авторизация"))
        }
    }

    @Test("жалоба на askpass-заглушку тоже читается как отказ авторизации")
    func askpassFailureIsAuthFailure() async throws {
        let git = FakeGit()
        // Именно этот текст git выдаёт из приложения: в терминале он пишет
        // «Authentication failed», а с askpass-заглушкой — жалобу на неё.
        // Замер на живом GitHub: код 128, 362 мс.
        git.result = GitResult(
            output: "",
            error: "error: unable to read askpass response from '/usr/bin/false'",
            status: 128
        )
        let service = GitService(git: git)

        do {
            try await service.push(at: repo)
            Issue.record("ожидалась ошибка")
        } catch let error as GitError {
            #expect(error.message.contains("Требуется авторизация"))
            #expect(!error.message.contains("askpass"))
        }
    }

    @Test("отсутствие upstream объясняется отдельно от отказа авторизации")
    func missingUpstreamHasOwnMessage() async throws {
        let git = FakeGit()
        git.result = GitResult(
            output: "",
            error: "fatal: The current branch feature has no upstream branch.",
            status: 128
        )
        let service = GitService(git: git)

        do {
            try await service.push(at: repo)
            Issue.record("ожидалась ошибка")
        } catch let error as GitError {
            #expect(error.message.contains("не связана с веткой на сервере"))
            #expect(!error.message.contains("Требуется авторизация"))
        }
    }

    @Test("прочая ошибка показывает текст git, а не проглатывается")
    func otherErrorKeepsGitText() async throws {
        let git = FakeGit()
        git.result = GitResult(output: "", error: "fatal: not a git repository", status: 128)
        let service = GitService(git: git)

        do {
            try await service.fetch(at: repo)
            Issue.record("ожидалась ошибка")
        } catch let error as GitError {
            #expect(error.message.contains("not a git repository"))
        }
    }

    @Test("нулевой код возврата ошибкой не считается, даже если git писал в stderr")
    func successIgnoresStderr() async throws {
        let git = FakeGit()
        // git пишет в stderr прогресс: «Receiving objects…» — это не ошибка.
        git.result = GitResult(output: "", error: "Receiving objects: 100%", status: 0)
        let service = GitService(git: git)

        try await service.fetch(at: repo)
    }
}

@Suite("Запуск git как процесса")
struct GitCLITests {

    @Test("окружение запрещает git спрашивать пароль")
    func environmentDisablesPrompts() {
        let environment = GitCLI.processEnvironment()

        // Без этого процесс без tty завис бы навсегда в ожидании ввода:
        // приложению нечем показать приглашение, а git ждёт его вечно.
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(environment["GIT_ASKPASS"] == "/usr/bin/false")
        #expect(environment["SSH_ASKPASS"] == "/usr/bin/false")
    }

    @Test("окружение сохраняет системные переменные, а не заменяет их")
    func environmentKeepsSystemVariables() {
        let environment = GitCLI.processEnvironment()

        // PATH и HOME нужны git, чтобы найти ssh и прочитать ~/.gitconfig:
        // без HOME он не увидит ни credential helper, ни настройки пользователя.
        #expect(environment["HOME"] != nil)
        #expect(environment["PATH"] != nil)
    }
}

@Suite("Имя папки из адреса репозитория")
struct CloneNameTests {

    @Test("берёт имя из https-адреса и убирает .git")
    func nameFromHTTPS() {
        #expect(GitService.suggestedName(for: "https://github.com/user/pathway.git") == "pathway")
        #expect(GitService.suggestedName(for: "https://github.com/user/pathway") == "pathway")
    }

    @Test("берёт имя из scp-подобного адреса SSH")
    func nameFromSSH() {
        // git@host:user/repo.git — не URL, а scp-синтаксис: разбор через
        // URLComponents дал бы здесь nil.
        #expect(GitService.suggestedName(for: "git@github.com:user/pathway.git") == "pathway")
    }

    @Test("лишний слэш в конце имени не мешает")
    func trailingSlashIgnored() {
        #expect(GitService.suggestedName(for: "https://github.com/user/pathway.git/") == "pathway")
    }

    @Test("для мусора имя не выдумывается")
    func garbageGivesNil() {
        #expect(GitService.suggestedName(for: "") == nil)
        #expect(GitService.suggestedName(for: "   ") == nil)
    }
}

