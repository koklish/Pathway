import Foundation
import Testing

@testable import PathwayCore

@Suite("Панель коммитов в состоянии приложения")
@MainActor
struct CommitsPanelStateTests {

    /// Своё хранилище вкладок: с общим тесты открыли бы сохранённую сессию
    /// пользователя вместо временной папки.
    private func makeState(path: URL, git: any GitRunning = SilentGit()) -> AppState {
        let suite = "commits.panel.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let tabs = TabsModel(
            path: path, store: TabsStore(defaults: defaults), git: GitService(git: git)
        )
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

    @Test("команда Commits открывает панель и закрывает повторным вызовом")
    func togglesPanel() throws {
        try withTempDir { dir in
            let repo = try makeRepo(in: dir, name: "Проект")
            let state = makeState(path: repo)

            CommandRegistry[.gitCommits].run(state)
            #expect(state.isCommitsPanelOpen)

            // Тот же пункт закрывает: отдельного «Закрыть» в меню нет, и
            // повторный клик обязан вернуть окно как было.
            CommandRegistry[.gitCommits].run(state)
            #expect(!state.isCommitsPanelOpen)
        }
    }

    @Test("Commits доступна во время операции, в отличие от Pull и Push")
    func availableWhileBusy() async throws {
        try await withTempDirAsync { dir in
            let repo = try makeRepo(in: dir, name: "Проект")
            let gate = OperationGate()
            let git = SlowGit(gate: gate)
            let state = makeState(path: repo, git: git)
            await state.browser.refreshRepository()

            // Занятость наступает от настоящей операции, а не от тестового
            // метода: проверять доступность команд по состоянию, которого в
            // работе не бывает, значило бы проверять не то.
            state.browser.gitFetch()
            await gate.untilStarted()

            // Панель только смотрит: погашенный вход в просмотр обещал бы
            // недоступность того, что доступно.
            #expect(state.browser.isBusy)
            #expect(CommandRegistry[.gitCommits].isEnabled(state))
            #expect(!CommandRegistry[.gitPull].isEnabled(state))

            await gate.open()
        }
    }

    @Test("Commits недоступна вне репозитория")
    func unavailableOutsideRepository() throws {
        try withTempDir { dir in
            let state = makeState(path: dir)

            #expect(!CommandRegistry[.gitCommits].isEnabled(state))
        }
    }

    @Test("Commits гасится при вводе текста")
    func disabledWhileEditingText() throws {
        try withTempDir { dir in
            let repo = try makeRepo(in: dir, name: "Проект")
            let state = makeState(path: repo)
            state.isEditingText = true

            // ⌥⌘G в адресной строке и в поле переименования принадлежит вводу.
            #expect(!CommandRegistry[.gitCommits].isEnabled(state))
        }
    }

    @Test("панель открывается для кликнутого репозитория, а не для текущего")
    func opensForClickedRepository() throws {
        try withTempDir { dir in
            // Стоя в папке с проектами, правым кликом по одному из них человек
            // ждёт историю именно его:действие над кликнутой строкой — нативное
            // поведение macOS, и панель обязана ему следовать.
            let clicked = try makeRepo(in: dir, name: "Другой проект")
            let state = makeState(path: dir)

            state.openCommitsPanel(for: clicked)

            #expect(state.isCommitsPanelOpen)
            #expect(state.commitsPanelRepository == clicked)
        }
    }

    @Test("команда из меню открывает панель для текущего репозитория")
    func menuCommandOpensCurrent() throws {
        try withTempDir { dir in
            let repo = try makeRepo(in: dir, name: "Проект")
            let state = makeState(path: repo)
            state.commitsPanelRepository = dir.appendingPathComponent("Старый")

            CommandRegistry[.gitCommits].run(state)

            // Цель сбрасывается: иначе ⌥⌘G показал бы историю проекта, по
            // которому кликали в прошлый раз, а не того, где человек стоит.
            #expect(state.isCommitsPanelOpen)
            #expect(state.commitsPanelRepository == nil)
        }
    }

    @Test("панель коммитов одна на приложение, а не на вкладку")
    func panelIsSharedAcrossTabs() throws {
        try withTempDir { dir in
            let repo = try makeRepo(in: dir, name: "Проект")
            let state = makeState(path: repo)

            // Панель показывает репозиторий, а не папку: у двух вкладок одного
            // проекта состояние было бы одинаковым, и второй экземпляр читал бы
            // ту же историю второй раз.
            state.commits.message = "Черновик"
            state.tabs.open(repo, activate: true)

            #expect(state.commits.message == "Черновик")
        }
    }
}

/// Ворота: держат git внутри операции, пока их не откроют.
private actor OperationGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var started: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false

    func wait() async {
        guard !isOpen else { return }
        hasStarted = true
        started.forEach { $0.resume() }
        started.removeAll()
        await withCheckedContinuation { waiting.append($0) }
    }

    func untilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { started.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}

/// git, застревающий в воротах: нужен, чтобы поймать состояние «идёт операция».
private struct SlowGit: GitRunning {
    let gate: OperationGate

    func run(_ arguments: [String], in directory: URL?) async throws -> GitResult {
        // Статус пропускается свободно: на нём стоит обновление чипа, и застрянь
        // он — операция не дошла бы до самой команды.
        if arguments.first != "status" { await gate.wait() }
        return GitResult(output: "# branch.head main\n", error: "", status: 0)
    }
}

/// git, отвечающий пустотой: нужен там, где сам git к проверке отношения не
/// имеет, а запускать настоящий значило бы ждать процесса на каждый тест.
private struct SilentGit: GitRunning {
    func run(_ arguments: [String], in directory: URL?) async throws -> GitResult {
        GitResult(output: "", error: "", status: 0)
    }
}
