import Foundation

/// Результат запуска git.
public struct GitResult: Sendable {
    public let output: String
    public let error: String
    public let status: Int32

    public init(output: String, error: String, status: Int32) {
        self.output = output
        self.error = error
        self.status = status
    }
}

/// Запускает git. Граница с ОС: в тестах подменяется фейком.
public protocol GitRunning: Sendable {
    func run(_ arguments: [String], in directory: URL?) async throws -> GitResult
}

/// Ошибка операции git с текстом, готовым к показу человеку.
public struct GitError: LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }

    public init(message: String) {
        self.message = message
    }

    /// Переводит жалобу git в текст с действием.
    ///
    /// Сырой stderr человеку ничего не говорит: «terminal prompts disabled»
    /// выглядит как поломка приложения, а не как отсутствие сохранённых
    /// учётных данных.
    public init(stderr: String) {
        let text = stderr.lowercased()
        let needsAuth = text.contains("could not read username")
            || text.contains("could not read password")
            || text.contains("terminal prompts disabled")
            || text.contains("permission denied (publickey)")
            || text.contains("authentication failed")
            // Именно так git жалуется, когда сработала наша askpass-заглушка:
            // «Authentication failed» он пишет в терминале, а из приложения —
            // жалобу на заглушку, и без этого правила человек увидел бы
            // «unable to read askpass response from '/usr/bin/false'».
            || text.contains("askpass")

        if needsAuth {
            message = """
                Требуется авторизация. Выполните операцию в терминале один раз, \
                чтобы система запомнила учётные данные, или настройте ключ SSH.
                """
        } else if text.contains("no upstream branch") {
            message = "Текущая ветка не связана с веткой на сервере. Выполните «git push -u» в терминале один раз."
        } else if text.contains("would be overwritten by checkout"), let files = Self.blockingFiles(stderr) {
            // Имена берутся из ответа git, а не из своего git status: git
            // знает точно, какие файлы мешают, а наша проверка «дерево
            // грязное» назвала бы виноватыми все правки, включая безобидные.
            message = """
                Незакоммиченные изменения в этих файлах будут потеряны:
                \(files.joined(separator: "\n"))

                Закоммитьте их или отложите через «git stash», затем повторите.
                """
        } else {
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            message = trimmed.isEmpty ? "Не удалось выполнить операцию git." : trimmed
        }
    }

    /// Файлы, из-за которых git отказался сменить ветку.
    ///
    /// Формат снят с настоящего git: имена идут строками с ведущей табуляцией
    /// между заголовком «error:» и строкой «Please commit». Табуляция и
    /// служит признаком — искать по отступу надёжнее, чем считать строки от
    /// заголовка: их число зависит от количества файлов.
    static func blockingFiles(_ stderr: String) -> [String]? {
        let files = stderr
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("\t") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return files.isEmpty ? nil : files
    }
}

/// Запускает настоящий git из системы.
public struct GitCLI: GitRunning {
    private let tool: URL

    /// Путь к инструменту подменяем ради одного теста — «git не установлен».
    /// Проверить эту ветку иначе нечем: на машине разработчика git есть всегда,
    /// а ошибка при его отсутствии — первое, что увидит человек без
    /// инструментов Xcode.
    public init(tool: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.tool = tool
    }

    public func run(_ arguments: [String], in directory: URL?) async throws -> GitResult {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.environment = Self.processEnvironment()
        if let directory { process.currentDirectoryURL = directory }

        let stdout = Pipe()
        let stderr = Pipe()
        // nullDevice, а не унаследованный вход: git, попросивший ввода, должен
        // немедленно получить EOF, а не ждать данных из чужого дескриптора.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        // Читаем потоки по мере поступления: git на большом клоне заполнит
        // буфер трубы и встанет намертво, если ждать его завершения молча.
        let collector = OutputCollector()
        stdout.fileHandleForReading.readabilityHandler = { collector.append($0.availableData, isError: false) }
        stderr.fileHandleForReading.readabilityHandler = { collector.append($0.availableData, isError: true) }
        // defer, а не снятие по месту ниже: при сбое самого запуска выход
        // происходит броском, обработчики остались бы висеть на дескрипторах и
        // держать collector, а трубы — неосушёнными.
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    // Своя ошибка, а не системная: NSFileNoSuchFileError уехал
                    // бы в общий describe и превратился в «Папка больше не
                    // существует» — про папку, с которой всё в порядке. На
                    // Mac без инструментов Xcode это первое, что увидит человек.
                    continuation.resume(throwing: GitError(
                        message: "Не удалось запустить git. Установите инструменты командной строки Xcode: xcode-select --install"
                    ))
                }
            }
        } onCancel: {
            process.terminate()
        }

        collector.append((try? stdout.fileHandleForReading.readToEnd()) ?? Data(), isError: false)
        collector.append((try? stderr.fileHandleForReading.readToEnd()) ?? Data(), isError: true)

        // Перед проверкой кода: убитый по SIGTERM git вернёт ненулевой код и
        // превратился бы в ложную ошибку вместо CancellationError.
        try Task.checkCancellation()

        return GitResult(output: collector.outputText, error: collector.errorText, status: process.terminationStatus)
    }

    /// Окружение процесса: системное плюс запрет спрашивать пароль.
    ///
    /// Системное сохраняется целиком, а не заменяется: без HOME git не найдёт
    /// ни ~/.gitconfig, ни credential helper, а без PATH — ssh.
    static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // Приложению нечем показать приглашение ввода, а git без этих запретов
        // ждал бы его вечно — операция висла бы, а не падала.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        return environment
    }
}

/// Копит вывод процесса из фоновых обработчиков чтения.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()

    func append(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if isError { error.append(data) } else { output.append(data) }
    }

    var outputText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: output, encoding: .utf8) ?? ""
    }

    var errorText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: error, encoding: .utf8) ?? ""
    }
}
