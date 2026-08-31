import Foundation
import Testing

@testable import PathwayCore

/// Подставной git для модели панели: отвечает по первому слову команды.
private final class PanelFakeGit: GitRunning, @unchecked Sendable {
    private(set) var calls: [[String]] = []
    var results: [String: String] = [:]
    var failsOn: String?
    /// Ждёт разрешения перед ответом: нужно, чтобы поймать состояние «идёт
    /// операция», пока она ещё не закончилась.
    var gate: (@Sendable () async -> Void)?

    func run(_ arguments: [String], in directory: URL?) async throws -> GitResult {
        calls.append(arguments)
        if let gate { await gate() }
        if let failsOn, arguments.first == failsOn {
            return GitResult(output: "", error: "не вышло", status: 1)
        }
        return GitResult(output: results[arguments.first ?? ""] ?? "", error: "", status: 0)
    }

    var commands: [String] { calls.compactMap(\.first) }
}

@Suite("Модель панели коммитов")
@MainActor
struct CommitsModelTests {

    private let repo = URL(fileURLWithPath: "/tmp/Проект")

    private func statusOutput(_ lines: String...) -> String {
        (["# branch.head main"] + lines).joined(separator: "\n")
    }

    private func logOutput(_ subjects: String...) -> String {
        subjects.enumerated().map { index, subject in
            ["hash\(index)", "", "i.kogan", "1756400000", "", subject]
                .joined(separator: "\u{1}")
        }.joined(separator: "\u{0}") + "\u{0}"
    }

    @Test("загрузка читает и изменения, и историю")
    func loadsChangesAndHistory() async {
        let git = PanelFakeGit()
        git.results["status"] = statusOutput("1 .M N... 100644 100644 100644 a b Sources/A.swift")
        git.results["log"] = logOutput("Версия 1.3.5")
        let model = CommitsModel(git: GitService(git: git))

        await model.load(repository: repo)

        #expect(model.changes.map(\.path) == ["Sources/A.swift"])
        #expect(model.commits.map(\.subject) == ["Версия 1.3.5"])
    }

    @Test("граф укладывается по загруженной истории")
    func buildsGraphRows() async {
        let git = PanelFakeGit()
        git.results["log"] = logOutput("Второй", "Первый")
        let model = CommitsModel(git: GitService(git: git))

        await model.load(repository: repo)

        // Строк графа ровно столько же, сколько коммитов: вью рисует их парами
        // и рассинхрон сдвинул бы линии относительно сообщений.
        #expect(model.rows.count == model.commits.count)
    }

    @Test("файлы из индекса приходят отмеченными")
    func stagedFilesComeChecked() async {
        let git = PanelFakeGit()
        git.results["status"] = statusOutput(
            "1 M. N... 100644 100644 100644 a b Sources/Готов.swift",
            "1 .M N... 100644 100644 100644 a b Sources/Нет.swift"
        )
        let model = CommitsModel(git: GitService(git: git))

        await model.load(repository: repo)

        // Галочки и индекс git — одно состояние, а не два: файл, добавленный в
        // терминале, обязан прийти сюда уже отмеченным.
        #expect(model.isChecked("Sources/Готов.swift"))
        #expect(!model.isChecked("Sources/Нет.swift"))
    }

    @Test("отметка файла добавляет его в индекс")
    func checkingStages() async {
        let git = PanelFakeGit()
        git.results["status"] = statusOutput("1 .M N... 100644 100644 100644 a b Sources/A.swift")
        let model = CommitsModel(git: GitService(git: git))
        await model.load(repository: repo)

        await model.setChecked(true, for: "Sources/A.swift")

        #expect(git.calls.contains(["add", "--", "Sources/A.swift"]))
    }

    @Test("снятие отметки убирает файл из индекса")
    func uncheckingUnstages() async {
        let git = PanelFakeGit()
        git.results["status"] = statusOutput("1 M. N... 100644 100644 100644 a b Sources/A.swift")
        let model = CommitsModel(git: GitService(git: git))
        await model.load(repository: repo)

        await model.setChecked(false, for: "Sources/A.swift")

        #expect(git.calls.contains(["reset", "--quiet", "HEAD", "--", "Sources/A.swift"]))
    }

    @Test("коммит запрещён без сообщения")
    func commitNeedsMessage() async {
        let git = PanelFakeGit()
        git.results["status"] = statusOutput("1 M. N... 100644 100644 100644 a b Sources/A.swift")
        let model = CommitsModel(git: GitService(git: git))
        await model.load(repository: repo)

        model.message = "   "

        // Пробелы сообщением не считаются: git принял бы их, и в истории
        // остался бы коммит с пустым заголовком.
        #expect(!model.canCommit)
    }

    @Test("коммит запрещён, когда не отмечено ни одного файла")
    func commitNeedsCheckedFiles() async {
        let git = PanelFakeGit()
        git.results["status"] = statusOutput("1 .M N... 100644 100644 100644 a b Sources/A.swift")
        let model = CommitsModel(git: GitService(git: git))
        await model.load(repository: repo)

        model.message = "Правка"

        #expect(!model.canCommit)
    }

    @Test("коммит разрешён при сообщении и хотя бы одном отмеченном файле")
    func commitAllowed() async {
        let git = PanelFakeGit()
        git.results["status"] = statusOutput("1 M. N... 100644 100644 100644 a b Sources/A.swift")
        let model = CommitsModel(git: GitService(git: git))
        await model.load(repository: repo)

        model.message = "Правка"

        #expect(model.canCommit)
    }

    @Test("коммит очищает поле сообщения и перечитывает историю")
    func commitClearsMessage() async {
        let git = PanelFakeGit()
        git.results["status"] = statusOutput("1 M. N... 100644 100644 100644 a b Sources/A.swift")
        let model = CommitsModel(git: GitService(git: git))
        await model.load(repository: repo)
        model.message = "Правка"

        await model.commit()

        #expect(git.calls.contains(["commit", "-m", "Правка"]))
        #expect(model.message.isEmpty)
        // Перечитывание обязательно: после коммита список изменений пуст, а в
        // истории появилась строка — оставь как было, панель врала бы.
        #expect(git.commands.filter { $0 == "log" }.count == 2)
    }

    @Test("неудавшийся коммит сохраняет сообщение")
    func failedCommitKeepsMessage() async {
        // Текст, набранный руками, — единственное, что нельзя восстановить:
        // очистка поля после отказа заставила бы писать заново.
        let git = PanelFakeGit()
        git.results["status"] = statusOutput("1 M. N... 100644 100644 100644 a b Sources/A.swift")
        git.failsOn = "commit"
        let model = CommitsModel(git: GitService(git: git))
        await model.load(repository: repo)
        model.message = "Правка"

        await model.commit()

        #expect(model.message == "Правка")
        #expect(model.errorMessage != nil)
    }

    @Test("во время операции панель занята")
    func busyDuringOperation() async {
        let git = PanelFakeGit()
        git.results["status"] = statusOutput("1 M. N... 100644 100644 100644 a b Sources/A.swift")
        let model = CommitsModel(git: GitService(git: git))
        await model.load(repository: repo)
        model.message = "Правка"

        // Ворота держат git внутри операции: без них состояние «занято»
        // существовало бы лишь между строками и поймать его было бы нечем.
        let opened = Gate()
        git.gate = { await opened.wait() }

        let task = Task { await model.commit() }
        await opened.untilWaiting()
        #expect(model.isBusy)
        #expect(!model.canCommit)

        await opened.open()
        await task.value
        #expect(!model.isBusy)
    }

    @Test("сообщение переживает перезагрузку панели")
    func messageSurvivesReload() async {
        // Панель перечитывает статус на каждое изменение файлов снаружи, и
        // затирать при этом набранный текст значило бы терять его на каждое
        // сохранение в редакторе.
        let git = PanelFakeGit()
        git.results["status"] = statusOutput("1 M. N... 100644 100644 100644 a b Sources/A.swift")
        let model = CommitsModel(git: GitService(git: git))
        await model.load(repository: repo)
        model.message = "Набранное"

        await model.load(repository: repo)

        #expect(model.message == "Набранное")
    }

    @Test("смена репозитория очищает поле сообщения")
    func switchingRepositoryClearsMessage() async {
        // Сообщение принадлежит репозиторию: перенеси его в другой — человек
        // закоммитил бы туда текст, написанный не про те изменения.
        let git = PanelFakeGit()
        let model = CommitsModel(git: GitService(git: git))
        await model.load(repository: repo)
        model.message = "Про первый проект"

        await model.load(repository: URL(fileURLWithPath: "/tmp/Другой"))

        #expect(model.message.isEmpty)
    }

    @Test("догрузка добавляет коммиты к уже показанным, а не заменяет их")
    func loadMoreAppends() async {
        let git = PanelFakeGit()
        git.results["log"] = logOutput("Первый")
        // Порция в один коммит: полная страница означает, что история на ней
        // не кончилась, и панель имеет право дочитывать дальше.
        let model = CommitsModel(git: GitService(git: git), pageSize: 1)
        await model.load(repository: repo)

        git.results["log"] = logOutput("Второй")
        await model.loadMore()

        #expect(model.commits.map(\.subject) == ["Первый", "Второй"])
        #expect(git.calls.contains { $0.contains("--skip=1") })
    }

    @Test("догрузка ничего не делает, когда история кончилась")
    func loadMoreStopsAtEnd() async {
        // Порция короче запрошенной означает конец: следующий запрос вернул бы
        // пустоту, и панель дёргала бы git на каждом касании конца списка.
        let git = PanelFakeGit()
        git.results["log"] = logOutput("Единственный")
        let model = CommitsModel(git: GitService(git: git), pageSize: 200)
        await model.load(repository: repo)

        let before = git.commands.filter { $0 == "log" }.count
        await model.loadMore()

        #expect(git.commands.filter { $0 == "log" }.count == before)
    }

    @Test("выбранный коммит показывает свои файлы")
    func selectingCommitLoadsItsFiles() async {
        let git = PanelFakeGit()
        git.results["log"] = logOutput("Версия 1.3.5")
        git.results["show"] = "M\tSources/A.swift\nA\tSources/B.swift\n"
        let model = CommitsModel(git: GitService(git: git))
        await model.load(repository: repo)

        await model.select(model.commits[0])

        #expect(model.selectedCommit?.subject == "Версия 1.3.5")
        #expect(model.selectedFiles.map(\.path) == ["Sources/A.swift", "Sources/B.swift"])
    }

    @Test("возврат из коммита к изменениям снимает выбор")
    func deselectingReturnsToChanges() async {
        let git = PanelFakeGit()
        git.results["log"] = logOutput("Версия 1.3.5")
        let model = CommitsModel(git: GitService(git: git))
        await model.load(repository: repo)
        await model.select(model.commits[0])

        model.deselect()

        #expect(model.selectedCommit == nil)
        #expect(model.selectedFiles.isEmpty)
    }
}

/// Ворота для теста: держат операцию внутри, пока её не отпустят.
private actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrived: [CheckedContinuation<Void, Never>] = []
    private var hasArrived = false

    func wait() async {
        guard !isOpen else { return }
        hasArrived = true
        arrived.forEach { $0.resume() }
        arrived.removeAll()
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Ждёт, пока операция дойдёт до ворот.
    func untilWaiting() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { arrived.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}
