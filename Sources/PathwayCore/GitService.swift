import Foundation

/// Операции над репозиторием целиком: состояние, обмен с сервером, клонирование.
///
/// Пофайловых операций здесь нет намеренно: commit, discard и ignore работают с
/// выделением и требуют своего интерфейса — это отдельная задача.
public struct GitService: Sendable {
    private let git: any GitRunning

    public init(git: any GitRunning = GitCLI()) {
        self.git = git
    }

    /// Состояние репозитория одним вызовом.
    ///
    /// Без -z намеренно: с ним git отдаёт имена как есть, и файл с переносом
    /// строки в имени разорвал бы разбор по строкам. Без -z такое имя
    /// закавычено, и перенос в разбор не попадает вовсе.
    public func status(at repository: URL) async throws -> GitStatus {
        let result = try await run(["status", "--porcelain=v2", "--branch"], in: repository)
        return GitStatus.parse(result.output)
    }

    public func fetch(at repository: URL) async throws {
        // --prune: без него удалённые на сервере ветки остаются в списке
        // локальных копий навсегда, и счётчик «позади» врёт.
        try await run(["fetch", "--prune"], in: repository)
    }

    public func pull(at repository: URL) async throws {
        // --ff-only: слияние может оставить репозиторий в конфликте, разрешать
        // который в файловом менеджере нечем. Лучше честный отказ.
        try await run(["pull", "--ff-only"], in: repository)
    }

    public func push(at repository: URL) async throws {
        try await run(["push"], in: repository)
    }

    /// Забирает чужие изменения и отдаёт свои.
    ///
    /// Одной операцией, а не двумя пунктами подряд: «забрать и отдать» — самое
    /// частое действие, и второй клик после ожидания первого ничего не решает.
    ///
    /// Порядок обязателен: push до pull отвергается сервером, если на нём
    /// появились чужие коммиты. Ошибка pull прерывает всё — push поверх
    /// неудавшегося слияния отправил бы не то состояние, которое человек видел.
    public func sync(at repository: URL) async throws {
        try await pull(at: repository)
        try await push(at: repository)
    }

    /// Коммит, на котором стоит рабочее дерево; nil — прочитать не удалось.
    ///
    /// Нужен, чтобы посчитать реально пришедшее: счётчик «позади» из status
    /// врёт, когда refs устарели, — а pull начинается с fetch и узнаёт о чужих
    /// коммитах уже внутри себя.
    public func head(at repository: URL) async throws -> String? {
        let result = try await run(["rev-parse", "HEAD"], in: repository)
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Сколько коммитов добавилось между двумя ревизиями.
    ///
    /// Именно rev-list, а не разница счётчиков: он отвечает на вопрос «что
    /// пришло за эту операцию» точно, независимо от того, насколько свежими
    /// были refs к её началу.
    public func commitCount(from oldHead: String, to newHead: String, at repository: URL) async throws -> Int {
        guard oldHead != newHead else { return 0 }
        let result = try await run(["rev-list", "--count", "\(oldHead)..\(newHead)"], in: repository)
        return Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Список веток репозитория, свежие первыми.
    ///
    /// Читается по требованию, без кэша: 75 веток настоящего репозитория
    /// выдаются за 16 мс, и хранить их значило бы держать список, который
    /// устареет от первой же операции в терминале.
    public func branches(at repository: URL) async throws -> [Branch] {
        let result = try await run(BranchList.arguments, in: repository)
        // Текущая ветка — отдельным дешёвым чтением файла, без второго
        // процесса: for-each-ref её не помечает.
        return BranchList.parse(result.output, current: GitRepository.branch(at: repository))
    }

    /// Переключает на локальную ветку.
    ///
    /// switch, а не checkout: у checkout две несвязанные роли — сменить ветку
    /// и восстановить файл, — и опечатка в аргументе там означает потерю
    /// правок. switch умеет только первое.
    public func switchBranch(to name: String, at repository: URL) async throws {
        try await run(["switch", name], in: repository)
    }

    /// Заводит локальную ветку по серверной и переключается на неё.
    ///
    /// Отдельный метод, а не флаг: снаружи это разные действия — «перейти» и
    /// «завести у себя», и кнопка в форме меняет надпись именно по нему.
    /// --track сразу ставит upstream, иначе первый же push потребовал бы
    /// «git push -u» в терминале.
    public func switchToRemote(_ name: String, remote: String = "origin", at repository: URL) async throws {
        try await run(["switch", "--track", "\(remote)/\(name)"], in: repository)
    }

    /// Клонирует репозиторий в папку назначения.
    ///
    /// Имя необязательно: пустое — пусть git возьмёт имя из адреса. Пустая
    /// строка отдельным аргументом заставила бы git клонировать в папку с
    /// пустым именем и упасть с невнятной ошибкой.
    public func clone(from url: String, into destination: URL, name: String) async throws {
        var arguments = ["clone", url]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { arguments.append(trimmed) }
        try await run(arguments, in: destination)
    }

    /// Имя папки, которое git выберет сам для этого адреса.
    ///
    /// Нужно диалогу, чтобы показать его заранее: пустое поле «Имя папки»
    /// заставляло бы гадать, куда всё попадёт.
    public static func suggestedName(for url: String) -> String? {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }

        // Разбор по последнему разделителю, а не через URLComponents: адреса
        // вида git@host:user/repo.git — это scp-синтаксис, а не URL, и
        // URLComponents вернул бы на них nil.
        let last = text.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init)
        guard var name = last, !name.isEmpty else { return nil }
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name.isEmpty ? nil : name
    }

    @discardableResult
    private func run(_ arguments: [String], in directory: URL) async throws -> GitResult {
        let result = try await git.run(arguments, in: directory)
        // Только по коду возврата: git пишет в stderr и прогресс — «Receiving
        // objects: 100%» ошибкой не является.
        guard result.status == 0 else { throw GitError(stderr: result.error) }
        return result
    }
}
