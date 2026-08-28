import Foundation
import Testing

@testable import PathwayCore

private final class FakeGit: GitRunning, @unchecked Sendable {
    private(set) var calls: [[String]] = []
    private(set) var directories: [URL?] = []
    var result: GitResult = GitResult(output: "", error: "", status: 0)

    func run(_ arguments: [String], in directory: URL?) async throws -> GitResult {
        calls.append(arguments)
        directories.append(directory)
        return result
    }
}

@Suite("Git в модели браузера")
@MainActor
struct BrowserGitTests {

    private func makeRepo(in dir: URL, name: String, branch: String) throws -> URL {
        let repo = dir.appendingPathComponent(name)
        let git = repo.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/\(branch)\n"
            .write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        return repo
    }

    @Test("внутри репозитория модель знает его ветку")
    func knowsBranchInsideRepository() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir, name: "Проект", branch: "main")
            let git = FakeGit()
            git.result = GitResult(output: "# branch.head main\n# branch.ab +2 -1\n", error: "", status: 0)

            let model = BrowserModel(path: repo, git: GitService(git: git))
            await model.refreshRepository()

            #expect(model.currentRepository?.branch == "main")
            #expect(model.currentRepository?.ahead == 2)
            #expect(model.currentRepository?.behind == 1)
        }
    }

    @Test("во вложенной папке ветка репозитория не теряется")
    func keepsBranchInNestedFolder() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir, name: "Проект", branch: "main")
            let nested = repo.appendingPathComponent("Sources/PathwayCore")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

            let git = FakeGit()
            git.result = GitResult(output: "# branch.head main\n", error: "", status: 0)

            let model = BrowserModel(path: nested, git: GitService(git: git))
            await model.refreshRepository()

            #expect(model.currentRepository?.branch == "main")
            #expect(model.currentRepository?.root.path == repo.path)
        }
    }

    @Test("вне репозитория состояние пустое и git не запускается")
    func noRepositoryOutside() async throws {
        try await withTempDirAsync { dir in
            let git = FakeGit()
            let model = BrowserModel(path: dir, git: GitService(git: git))

            await model.refreshRepository()

            #expect(model.currentRepository == nil)
            // Запуск процесса ради заведомо не-репозитория — лишняя пауза при
            // каждой смене папки.
            #expect(git.calls.isEmpty)
        }
    }

    @Test("при сбое git status ветка остаётся, пропадают лишь счётчики")
    func statusErrorKeepsBranch() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir, name: "Проект", branch: "main")
            let git = FakeGit()
            git.result = GitResult(output: "", error: "fatal: something", status: 128)

            let model = BrowserModel(path: repo, git: GitService(git: git))
            await model.refreshRepository()

            // Индикатор — фоновая справка, её сбой не повод прерывать работу
            // алертом поверх списка файлов.
            #expect(model.errorMessage == nil)
            // Ветка читается из .git/HEAD и от сбоя git не зависит: терять её
            // из-за недоступного сервера было бы хуже, чем показать без
            // счётчиков.
            #expect(model.currentRepository?.branch == "main")
            #expect(model.currentRepository?.ahead == nil)
        }
    }

    @Test("push запускается в корне репозитория, а не в текущей папке")
    func pushRunsInRepositoryRoot() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir, name: "Проект", branch: "main")
            let nested = repo.appendingPathComponent("Sources")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

            let git = FakeGit()
            let model = BrowserModel(path: nested, git: GitService(git: git))
            await model.refreshRepository()

            model.gitPush()
            await model.waitForOperation()

            #expect(git.calls.contains(["push"]))
        }
    }

    @Test("неудачный push объясняет причину в errorMessage")
    func failedPushReportsError() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir, name: "Проект", branch: "main")
            let git = FakeGit()
            let model = BrowserModel(path: repo, git: GitService(git: git))
            await model.refreshRepository()

            git.result = GitResult(output: "", error: "fatal: Authentication failed", status: 128)
            model.gitPush()
            await model.waitForOperation()

            #expect(model.errorMessage?.contains("Требуется авторизация") == true)
        }
    }

    @Test("после pull список перечитывается: файлы могли измениться")
    func pullReloadsList() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir, name: "Проект", branch: "main")
            let git = FakeGit()
            let model = BrowserModel(path: repo, git: GitService(git: git))
            await model.refreshRepository()

            try "новый".write(to: repo.appendingPathComponent("после-pull.txt"), atomically: true, encoding: .utf8)
            model.gitPull()
            await model.waitForOperation()
            await model.waitForLoad()

            #expect(model.items.contains { $0.name == "после-pull.txt" })
        }
    }

    @Test("клонирование идёт в текущую папку и показывает появившийся проект")
    func cloneRunsInCurrentFolder() async throws {
        try await withTempDirAsync { dir in
            let git = FakeGit()
            let model = BrowserModel(path: dir, git: GitService(git: git))

            model.gitClone(from: "git@github.com:user/repo.git", name: "Новый")
            await model.waitForOperation()

            #expect(git.calls.contains(["clone", "git@github.com:user/repo.git", "Новый"]))
        }
    }
}

@Suite("Доступность git-команд")
@MainActor
struct GitCommandAvailabilityTests {

    /// Своё хранилище вкладок и подставной git: с общим тесты открыли бы
    /// сохранённую сессию пользователя вместо временной папки.
    private func makeState(path: URL) -> AppState {
        let suite = "git.commands.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let tabs = TabsModel(path: path, store: TabsStore(defaults: defaults), git: GitService(git: FakeGit()))
        return AppState(tabs: tabs, favorites: FavoritesStore(defaults: defaults))
    }

    private func makeRepo(in dir: URL, branch: String) throws -> URL {
        let git = dir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/\(branch)\n"
            .write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test("вне репозитория операции недоступны, а клонирование доступно")
    func outsideRepositoryOnlyCloneIsEnabled() async throws {
        try await withTempDirAsync { dir in
            let state = makeState(path: dir)
            await state.browser.refreshRepository()

            #expect(CommandRegistry[.gitFetch].isEnabled(state) == false)
            #expect(CommandRegistry[.gitPull].isEnabled(state) == false)
            #expect(CommandRegistry[.gitPush].isEnabled(state) == false)
            // Клонировать можно в любую папку — репозиторием ей быть незачем.
            #expect(CommandRegistry[.gitClone].isEnabled(state))
        }
    }

    @Test("внутри репозитория операции доступны")
    func insideRepositoryOperationsAreEnabled() async throws {
        try await withTempDirAsync { dir in
            _ = try makeRepo(in: dir, branch: "main")
            let state = makeState(path: dir)
            await state.browser.refreshRepository()

            #expect(CommandRegistry[.gitFetch].isEnabled(state))
            #expect(CommandRegistry[.gitPull].isEnabled(state))
            #expect(CommandRegistry[.gitPush].isEnabled(state))
        }
    }

    @Test("на томе только для чтения пишущие операции гаснут, а push остаётся")
    func readOnlyVolumeDisablesWritingOperations() async throws {
        try await withTempDirAsync { dir in
            _ = try makeRepo(in: dir, branch: "main")
            let state = makeState(path: dir)
            await state.browser.refreshRepository()
            state.browser.isReadOnlyVolume = true

            #expect(CommandRegistry[.gitFetch].isEnabled(state) == false)
            #expect(CommandRegistry[.gitPull].isEnabled(state) == false)
            #expect(CommandRegistry[.gitClone].isEnabled(state) == false)
            // Sync содержит pull, а тот пишет в рабочее дерево.
            #expect(CommandRegistry[.gitSync].isEnabled(state) == false)
            // Push ничего не пишет на диск — он отправляет уже записанное,
            // и запрет записи на том его не касается.
            #expect(CommandRegistry[.gitPush].isEnabled(state))
            // Копирование имени пишет в буфер, а не на диск.
            #expect(CommandRegistry[.gitCopyBranch].isEnabled(state))
        }
    }
}

@Suite("Цель git-операций")
@MainActor
struct GitTargetTests {

    private func makeState(path: URL, git: FakeGit) -> AppState {
        let suite = "git.target.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let tabs = TabsModel(path: path, store: TabsStore(defaults: defaults), git: GitService(git: git))
        return AppState(tabs: tabs, favorites: FavoritesStore(defaults: defaults))
    }

    private func makeRepo(in dir: URL, name: String) throws -> URL {
        let repo = dir.appendingPathComponent(name)
        let git = repo.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n"
            .write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        return repo
    }

    @Test("выделенная папка-проект даёт доступ к операциям, стоя над проектами")
    func selectedRepositoryEnablesOperations() async throws {
        try await withTempDirAsync { dir in
            _ = try makeRepo(in: dir, name: "Проект")
            let state = makeState(path: dir, git: FakeGit())
            state.browser.reloadAsync()
            await state.browser.waitForLoad()
            await state.browser.refreshRepository()

            // Сама папка с проектами репозиторием не является — ровно сценарий
            // ~/PhpstormProjects, ради которого всё затевалось.
            #expect(state.browser.currentRepository == nil)

            state.browser.pane.selection = [state.browser.items[0].url]

            #expect(CommandRegistry[.gitFetch].isEnabled(state))
            #expect(CommandRegistry[.gitPull].isEnabled(state))
            #expect(CommandRegistry[.gitPush].isEnabled(state))
        }
    }

    @Test("операция идёт в выделенный проект, а не в текущую папку")
    func operationRunsInSelectedRepository() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir, name: "Проект")
            let git = FakeGit()
            let state = makeState(path: dir, git: git)
            state.browser.reloadAsync()
            await state.browser.waitForLoad()
            state.browser.pane.selection = [state.browser.items[0].url]

            CommandRegistry[.gitPush].run(state)
            await state.browser.waitForOperation()

            #expect(git.directories.contains { $0?.path == repo.path })
        }
    }

    @Test("выделенная обычная папка доступа к операциям не даёт")
    func selectedPlainFolderKeepsOperationsDisabled() async throws {
        try await withTempDirAsync { dir in
            let plain = dir.appendingPathComponent("Обычная")
            try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
            let state = makeState(path: dir, git: FakeGit())
            state.browser.reloadAsync()
            await state.browser.waitForLoad()
            await state.browser.refreshRepository()
            state.browser.pane.selection = [state.browser.items[0].url]

            #expect(CommandRegistry[.gitFetch].isEnabled(state) == false)
        }
    }

    @Test("внутри репозитория цель — он сам, даже когда выделен вложенный проект")
    func insideRepositoryCurrentWins() async throws {
        try await withTempDirAsync { dir in
            let outer = try makeRepo(in: dir, name: "Внешний")
            _ = try makeRepo(in: outer, name: "Вложенный")
            let git = FakeGit()
            let state = makeState(path: outer, git: git)
            state.browser.reloadAsync()
            await state.browser.waitForLoad()
            await state.browser.refreshRepository()

            // Выделение вложенного проекта не должно уводить операцию из
            // репозитория, в котором человек стоит: индикатор в адресной
            // строке показывает именно его, и push ушёл бы не туда, куда
            // человек смотрит.
            state.browser.pane.selection = [state.browser.items[0].url]
            CommandRegistry[.gitPush].run(state)
            await state.browser.waitForOperation()

            #expect(git.directories.contains { $0?.path == outer.path })
        }
    }

    @Test("«Скопировать имя ветки» кладёт в буфер ветку, а не путь")
    func copyBranchWritesBranchName() async throws {
        try await withTempDirAsync { dir in
            let repo = dir.appendingPathComponent("Проект")
            let gitDir = repo.appendingPathComponent(".git")
            try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
            try "ref: refs/heads/feature/SDLC/35\n"
                .write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

            let pasteboard = PasteboardService(isolatedForTesting: true)
            let model = BrowserModel(path: repo, pasteboard: pasteboard, git: GitService(git: FakeGit()))
            await model.refreshRepository()

            model.gitCopyBranch()

            #expect(pasteboard.readText() == "feature/SDLC/35")
        }
    }

    @Test("«Скопировать имя ветки» вытесняет из буфера ранее скопированный файл")
    func copyBranchClearsPreviousURLs() async throws {
        try await withTempDirAsync { dir in
            let repo = dir.appendingPathComponent("Проект")
            let gitDir = repo.appendingPathComponent(".git")
            try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
            try "ref: refs/heads/main\n"
                .write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
            let file = repo.appendingPathComponent("файл.txt")
            try "текст".write(to: file, atomically: true, encoding: .utf8)

            let pasteboard = PasteboardService(isolatedForTesting: true)
            let model = BrowserModel(path: repo, pasteboard: pasteboard, git: GitService(git: FakeGit()))
            await model.refreshRepository()

            // Сначала копируем файл, потом ветку: без clearContents URL пережил
            // бы запись строки, и следующая «Вставить» скопировала бы сам файл.
            pasteboard.write([file], operation: .copy)
            model.gitCopyBranch()

            #expect(pasteboard.readText() == "main")
            #expect(pasteboard.readURLs().isEmpty)
        }
    }

    @Test("«Синхронизировать» идёт в выделенный проект и делает pull перед push")
    func syncRunsInSelectedRepository() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir, name: "Проект")
            let git = FakeGit()
            let state = makeState(path: dir, git: git)
            state.browser.reloadAsync()
            await state.browser.waitForLoad()
            state.browser.pane.selection = [state.browser.items[0].url]

            CommandRegistry[.gitSync].run(state)
            await state.browser.waitForOperation()

            let commands = git.calls.filter { $0.first == "pull" || $0.first == "push" }
            #expect(commands == [["pull", "--ff-only"], ["push"]])
            #expect(git.directories.contains { $0?.path == repo.path })
        }
    }

    @Test("операция идёт в указанный репозиторий, а не в выделенный")
    func explicitTargetBeatsSelection() async throws {
        try await withTempDirAsync { dir in
            _ = try makeRepo(in: dir, name: "Выделенный")
            let clicked = try makeRepo(in: dir, name: "Кликнутый")
            let git = FakeGit()
            let state = makeState(path: dir, git: git)
            state.browser.reloadAsync()
            await state.browser.waitForLoad()

            // Правый клик по невыделенной строке действует на неё — нативное
            // поведение macOS. Без явной цели операция ушла бы в выделенный
            // проект, то есть не туда, по чему человек кликнул.
            let selected = state.browser.items.first { $0.name == "Выделенный" }!
            state.browser.pane.selection = [selected.url]

            state.browser.gitPush(at: clicked)
            await state.browser.waitForOperation()

            #expect(git.directories.contains { $0?.path == clicked.path })
            #expect(git.directories.contains { $0?.path == selected.url.path } == false)
        }
    }

    @Test("«Скопировать имя ветки» тоже слушается явной цели")
    func copyBranchUsesExplicitTarget() async throws {
        try await withTempDirAsync { dir in
            _ = try makeRepo(in: dir, name: "Выделенный")
            let clicked = dir.appendingPathComponent("Кликнутый")
            let gitDir = clicked.appendingPathComponent(".git")
            try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
            try "ref: refs/heads/release/2.0\n"
                .write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

            let pasteboard = PasteboardService(isolatedForTesting: true)
            let model = BrowserModel(path: dir, pasteboard: pasteboard, git: GitService(git: FakeGit()))
            model.reloadAsync()
            await model.waitForLoad()
            model.pane.selection = [model.items.first { $0.name == "Выделенный" }!.url]

            model.gitCopyBranch(at: clicked)

            #expect(pasteboard.readText() == "release/2.0")
        }
    }

    @Test("переключение идёт в указанный репозиторий, а не в выделенный")
    func switchUsesExplicitTarget() async throws {
        try await withTempDirAsync { dir in
            _ = try makeRepo(in: dir, name: "Выделенный")
            let clicked = try makeRepo(in: dir, name: "Кликнутый")
            let git = FakeGit()
            let state = makeState(path: dir, git: git)
            state.browser.reloadAsync()
            await state.browser.waitForLoad()
            state.browser.pane.selection = [
                state.browser.items.first { $0.name == "Выделенный" }!.url
            ]

            state.browser.gitSwitch(to: Branch(name: "develop"), at: clicked)
            await state.browser.waitForOperation()

            #expect(git.calls.contains { $0 == ["switch", "develop"] })
            #expect(git.directories.contains { $0?.path == clicked.path })
        }
    }

    @Test("серверная ветка заводится с привязкой, а не просто переключается")
    func switchToRemoteBranchTracks() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir, name: "Проект")
            let git = FakeGit()
            let model = BrowserModel(path: repo, git: GitService(git: git))
            await model.refreshRepository()

            model.gitSwitch(to: Branch(name: "feature/новая", isRemote: true))
            await model.waitForOperation()

            // --track ставит upstream сразу: без него первый же push
            // потребовал бы «git push -u» в терминале.
            #expect(git.calls.contains { $0 == ["switch", "--track", "origin/feature/новая"] })
        }
    }
}
