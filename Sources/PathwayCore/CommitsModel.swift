import Foundation
import Observation

/// Состояние панели коммитов: изменения рабочего дерева и история.
///
/// Отдельная модель, а не часть BrowserModel: панель может быть закрыта, и
/// тогда ни история, ни список изменений не читаются вовсе — держи их в модели
/// браузера, каждая смена папки платила бы за git log, которого никто не видит.
@Observable
@MainActor
public final class CommitsModel {

    /// Незакоммиченные файлы. Порядок — как их отдал git.
    public private(set) var changes: [GitChange] = []
    /// История, свежие первыми.
    public private(set) var commits: [Commit] = []
    /// Строки графа, по одной на коммит и в том же порядке.
    public private(set) var rows: [GraphRow] = []

    /// Сообщение будущего коммита. Живёт в модели, а не во вью: панель
    /// перечитывает статус на каждое изменение файлов снаружи, и от
    /// пересоздания вью текст терялся бы на каждое сохранение в редакторе.
    public var message: String = ""

    /// Выбранный в истории коммит; nil — панель показывает изменения.
    public private(set) var selectedCommit: Commit?
    /// Файлы выбранного коммита.
    public private(set) var selectedFiles: [GitChange] = []

    /// Идёт операция: галочки и кнопки на это время гаснут.
    public private(set) var isBusy = false
    /// Текст ошибки для алерта; nil — ошибки нет.
    public var errorMessage: String?

    /// Репозиторий, который показан сейчас; nil — панель ещё не загружена.
    public private(set) var repository: URL?

    /// Кончилась ли история: дочитывать больше нечего.
    private var reachedEnd = false

    private let git: GitService
    private let pageSize: Int

    public init(git: GitService = GitService(), pageSize: Int = 200) {
        self.git = git
        self.pageSize = pageSize
    }

    /// Отмечен ли файл — войдёт ли он в коммит.
    ///
    /// Спрашивается у самого git, а не у своего множества: индекс git и
    /// галочки суть одно состояние, и файл, добавленный в терминале, обязан
    /// прийти сюда уже отмеченным.
    public func isChecked(_ path: String) -> Bool {
        changes.first { $0.path == path }?.isStaged ?? false
    }

    /// Можно ли коммитить: есть сообщение и хотя бы один отмеченный файл.
    public var canCommit: Bool {
        !isBusy
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && changes.contains(where: \.isStaged)
    }

    /// Сколько файлов уйдёт в коммит — числом на кнопке.
    public var checkedCount: Int {
        changes.count(where: \.isStaged)
    }

    // MARK: - Загрузка

    /// Читает изменения и первую порцию истории.
    public func load(repository: URL) async {
        // Смена репозитория обнуляет всё, что принадлежит прежнему. Сообщение
        // в том числе: перенеси его — человек закоммитил бы в другой проект
        // текст, написанный не про те изменения.
        if self.repository != repository {
            self.repository = repository
            message = ""
            commits = []
            rows = []
            changes = []
            deselect()
        }
        reachedEnd = false

        await reloadChanges()
        await reloadHistory()
    }

    /// Перечитывает всё, не трогая набранное сообщение и выбор.
    public func refresh() async {
        guard repository != nil else { return }
        await reloadChanges()
        await reloadHistory()
    }

    /// Дочитывает следующую порцию истории.
    public func loadMore() async {
        guard let repository, !reachedEnd, !isBusy else { return }
        do {
            let next = try await git.log(at: repository, limit: pageSize, skip: commits.count)
            // Порция короче запрошенной означает конец истории: иначе панель
            // дёргала бы git на каждом касании конца списка.
            if next.count < pageSize { reachedEnd = true }
            guard !next.isEmpty else { return }

            commits += next
            rows = GitGraph.build(commits)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Не удалось прочитать историю."
        }
    }

    private func reloadChanges() async {
        guard let repository else { return }
        changes = (try? await git.changes(at: repository)) ?? []
    }

    private func reloadHistory() async {
        guard let repository else { return }
        let loaded = (try? await git.log(at: repository, limit: pageSize)) ?? []
        // Конец истории отмечается и здесь: репозиторий с тремя коммитами
        // иначе просил бы догрузку при каждом касании низа списка.
        reachedEnd = loaded.count < pageSize
        commits = loaded
        rows = GitGraph.build(loaded)
    }

    // MARK: - Отметки

    /// Отмечает или снимает отметку с файла.
    public func setChecked(_ checked: Bool, for path: String) async {
        guard let repository else { return }
        await perform("Не удалось изменить состав коммита") {
            if checked {
                try await self.git.stage([path], at: repository)
            } else {
                try await self.git.unstage([path], at: repository)
            }
        }
        await reloadChanges()
    }

    /// Отмечает или снимает отметку со всех файлов разом.
    public func setAllChecked(_ checked: Bool) async {
        guard let repository else { return }
        // Конфликтные файлы пропускаются: добавить их в индекс значит объявить
        // конфликт разрешённым, а разрешать его в файловом менеджере нечем.
        let paths = changes.filter { $0.status != .conflicted }.map(\.path)
        guard !paths.isEmpty else { return }

        await perform("Не удалось изменить состав коммита") {
            if checked {
                try await self.git.stage(paths, at: repository)
            } else {
                try await self.git.unstage(paths, at: repository)
            }
        }
        await reloadChanges()
    }

    // MARK: - Операции

    /// Создаёт коммит из отмеченных файлов. Возвращает, удался ли он.
    ///
    /// Именно результат, а не пустоту поля: «Закоммитить и Push» обязан
    /// отличить отказ от удачи, а судить об этом по очистке сообщения значило
    /// бы выводить одно состояние из следа другого.
    @discardableResult
    public func commit() async -> Bool {
        guard let repository, canCommit else { return false }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)

        let succeeded = await perform("Не удалось создать коммит") {
            try await self.git.commit(message: text, at: repository)
        }

        // Поле очищается только после удачи: текст, набранный руками, —
        // единственное, что нельзя восстановить, и очистка после отказа
        // заставила бы писать заново.
        if succeeded { message = "" }

        await refresh()
        return succeeded
    }

    /// Откатывает изменения перечисленных файлов.
    public func discard(_ paths: [String]) async {
        guard let repository, !paths.isEmpty else { return }

        // Неотслеживаемые удаляются, остальные восстанавливаются: git restore
        // на файле, которого нет в HEAD, падает — восстанавливать нечего.
        let untracked = Set(changes.filter { $0.status == .untracked }.map(\.path))
        let selected = Set(paths)

        await perform("Не удалось откатить изменения") {
            try await self.git.discard(
                Array(selected.subtracting(untracked)),
                untracked: Array(selected.intersection(untracked)),
                at: repository
            )
        }
        await reloadChanges()
    }

    // MARK: - Выбор коммита

    /// Показывает файлы выбранного коммита вместо списка изменений.
    public func select(_ commit: Commit) async {
        guard let repository else { return }
        selectedCommit = commit
        selectedFiles = (try? await git.files(of: commit.hash, at: repository)) ?? []
    }

    public func deselect() {
        selectedCommit = nil
        selectedFiles = []
    }

    /// Выполняет операцию, помечая панель занятой. Возвращает, удалась ли она.
    @discardableResult
    private func perform(_ failure: String, _ body: @escaping () async throws -> Void) async -> Bool {
        isBusy = true
        defer { isBusy = false }

        do {
            try await body()
            return true
        } catch is CancellationError {
            // Отмена не ошибка: тем же правилом живут файловые операции.
            return false
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? failure
            return false
        }
    }
}
