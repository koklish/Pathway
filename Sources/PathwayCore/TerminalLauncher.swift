import AppKit
import Foundation
import Observation

/// Известный терминал и способ его запустить.
public struct TerminalApp: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let launch: LaunchMethod

    public enum LaunchMethod: Equatable, Sendable {
        /// Бинарник принимает рабочую папку и команду аргументами: Ghostty, WezTerm, kitty, Alacritty.
        /// В шаблонах «%@» заменяется на значение; shell не участвует, экранирование не нужно.
        case executable(path: String, workdirArgs: [String], commandArgs: [String])
        /// Управление через AppleScript: Terminal.app, iTerm2.
        ///
        /// `openViaLaunchServices` включает обход для простого открытия папки:
        /// Launch Services умеет отдать её терминалу напрямую, без Apple Events,
        /// а значит и без запроса разрешения на автоматизацию. Для запуска
        /// команды обхода нет — там AppleScript обязателен.
        case appleScript(open: String, command: String, openViaLaunchServices: Bool = false)
    }

    public init(id: String, name: String, launch: LaunchMethod) {
        self.id = id
        self.name = name
        self.launch = launch
    }
}

public enum TerminalError: LocalizedError, Equatable {
    case launchFailed(String, String)
    /// macOS не дала управлять другим приложением — нужно разрешение в настройках.
    case automationDenied(String)

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(app, reason):
            "Не удалось запустить «\(app)». \(reason)"
        case let .automationDenied(app):
            "Нет разрешения управлять приложением «\(app)». Откройте Системные настройки → Конфиденциальность и безопасность → Автоматизация и разрешите Pathway управлять «\(app)»."
        }
    }
}

/// Абстракция запуска — чтобы в тестах проверять намерение, ничего не открывая.
@MainActor
public protocol TerminalRunning {
    func run(executable: String, arguments: [String]) throws
    func runAppleScript(_ source: String) throws
    /// Открывает папку в приложении средствами Launch Services.
    func open(folder: URL, inAppWithBundleID bundleID: String) throws
}

/// Настоящий запуск: процесс или AppleScript.
@MainActor
public struct SystemTerminalRunner: TerminalRunning {
    public init() {}

    public func run(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            throw TerminalError.launchFailed(
                URL(fileURLWithPath: executable).lastPathComponent,
                error.localizedDescription
            )
        }
    }

    /// Просит Launch Services открыть папку в указанном приложении.
    ///
    /// Терминалы трактуют переданную папку как рабочую и запускают в ней оболочку.
    /// В отличие от AppleScript, здесь не задействованы Apple Events, поэтому
    /// macOS не спрашивает разрешение на управление другим приложением.
    public func open(folder: URL, inAppWithBundleID bundleID: String) throws {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw TerminalError.launchFailed("Терминал", "Приложение не найдено в системе.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", app.path, folder.path]
        do {
            try process.run()
        } catch {
            throw TerminalError.launchFailed(
                app.deletingPathExtension().lastPathComponent,
                error.localizedDescription
            )
        }
    }

    public func runAppleScript(_ source: String) throws {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw TerminalError.launchFailed("Терминал", "Не удалось собрать скрипт запуска.")
        }
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return }

        let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
        let app = errorInfo[NSAppleScript.errorAppName] as? String ?? "Терминал"
        // -1743 — пользователь не выдал разрешение на автоматизацию; подсказка здесь важнее текста ошибки.
        if code == -1743 {
            throw TerminalError.automationDenied(app)
        }
        let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Неизвестная ошибка."
        throw TerminalError.launchFailed(app, message)
    }
}

/// Выбор терминала и запуск в нём папки или команды.
@Observable
@MainActor
public final class TerminalLauncher {
    public let available: [TerminalApp]

    private let defaults: UserDefaults
    private let runner: any TerminalRunning
    private let key = "terminal.preferred"

    public init(
        defaults: UserDefaults = .standard,
        available: [TerminalApp]? = nil,
        runner: (any TerminalRunning)? = nil
    ) {
        self.defaults = defaults
        self.available = available ?? Self.installed()
        self.runner = runner ?? SystemTerminalRunner()
    }

    /// Терминал, в котором открываем папки: выбранный пользователем, иначе первый
    /// доступный. Terminal.app есть в любой macOS, поэтому он — гарантированный фолбэк.
    public var preferred: TerminalApp {
        if let stored = defaults.string(forKey: key),
           let match = available.first(where: { $0.id == stored }) {
            return match
        }
        return available.first ?? .terminalApp
    }

    public func select(_ terminal: TerminalApp) {
        defaults.set(terminal.id, forKey: key)
    }

    // MARK: - Запуск

    public func openTerminal(at folder: URL) throws {
        try launch(at: folder, command: nil)
    }

    public func runCommand(_ command: String, at folder: URL) throws {
        try launch(at: folder, command: command)
    }

    private func launch(at folder: URL, command: String?) throws {
        let terminal = preferred
        switch terminal.launch {
        case let .executable(path, workdirArgs, commandArgs):
            var arguments = workdirArgs.map { $0.replacingOccurrences(of: "%@", with: folder.path) }
            if let command {
                arguments += commandArgs.map { $0.replacingOccurrences(of: "%@", with: command) }
            }
            try runner.run(executable: path, arguments: arguments)

        case let .appleScript(open, commandTemplate, viaLaunchServices):
            // Открытие папки без команды обходится без Apple Events — это снимает
            // запрос разрешения на автоматизацию в самом частом сценарии.
            if command == nil, viaLaunchServices {
                try runner.open(folder: folder, inAppWithBundleID: terminal.id)
                return
            }
            let template = command == nil ? open : commandTemplate
            var script = template.replacingOccurrences(
                of: "%path%",
                with: Self.escapeForAppleScript(folder.path)
            )
            if let command {
                // Внутри do script путь проходит через shell, поэтому здесь
                // нужны и shell-кавычки, и экранирование самого AppleScript.
                let shellLine = "cd \(Self.quoteForShell(folder.path)) && \(command)"
                script = script.replacingOccurrences(
                    of: "%command%",
                    with: Self.escapeForAppleScript(shellLine)
                )
            }
            try runner.runAppleScript(script)
        }
    }

    // MARK: - Экранирование

    /// Готовит строку для вставки в строковый литерал AppleScript.
    ///
    /// Обратный слэш обрабатывается первым: иначе экранирование кавычки
    /// добавит слэш, который следующая замена испортит ещё раз.
    static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
            .replacingOccurrences(of: "\n", with: #"\n"#)
            .replacingOccurrences(of: "\r", with: #"\r"#)
    }

    /// Оборачивает путь в одинарные кавычки для shell.
    /// Апостроф внутри закрывает кавычку, поэтому его заменяем на '\''.
    static func quoteForShell(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: - Поиск установленных терминалов

    /// Терминалы, которые реально есть в системе, в порядке предпочтения.
    private static func installed() -> [TerminalApp] {
        var found = known.filter { isInstalled($0) }
        // Системный терминал есть всегда — он замыкает список как надёжный запасной вариант.
        if !found.contains(where: { $0.id == TerminalApp.terminalApp.id }) {
            found.append(.terminalApp)
        }
        return found
    }

    private static func isInstalled(_ terminal: TerminalApp) -> Bool {
        switch terminal.launch {
        case let .executable(path, _, _):
            return FileManager.default.isExecutableFile(atPath: path)
        case .appleScript:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.id) != nil
        }
    }

    /// Реестр известных терминалов. Порядок задаёт приоритет автовыбора:
    /// сначала то, что пользователь ставил осознанно, системный — последним.
    public static let known: [TerminalApp] = [
        .iTerm2,
        .ghostty,
        .wezTerm,
        .kitty,
        .alacritty,
        .terminalApp,
    ]
}

// MARK: - Известные терминалы

public extension TerminalApp {
    static let terminalApp = TerminalApp(
        id: "com.apple.Terminal",
        name: "Терминал",
        launch: .appleScript(
            open: """
            tell application "Terminal"
                activate
                do script "cd %path%"
            end tell
            """,
            command: """
            tell application "Terminal"
                activate
                do script "%command%"
            end tell
            """,
            openViaLaunchServices: true
        )
    )

    static let iTerm2 = TerminalApp(
        id: "com.googlecode.iterm2",
        name: "iTerm2",
        launch: .appleScript(
            open: """
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "cd %path%"
                end tell
            end tell
            """,
            command: """
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "%command%"
                end tell
            end tell
            """,
            openViaLaunchServices: true
        )
    )

    static let ghostty = TerminalApp(
        id: "com.mitchellh.ghostty",
        name: "Ghostty",
        launch: .executable(
            path: "/Applications/Ghostty.app/Contents/MacOS/ghostty",
            workdirArgs: ["--working-directory=%@"],
            commandArgs: ["-e", "%@"]
        )
    )

    static let wezTerm = TerminalApp(
        id: "com.github.wez.wezterm",
        name: "WezTerm",
        launch: .executable(
            path: "/Applications/WezTerm.app/Contents/MacOS/wezterm",
            workdirArgs: ["start", "--cwd", "%@"],
            commandArgs: ["--", "%@"]
        )
    )

    static let kitty = TerminalApp(
        id: "net.kovidgoyal.kitty",
        name: "kitty",
        launch: .executable(
            path: "/Applications/kitty.app/Contents/MacOS/kitty",
            workdirArgs: ["--directory", "%@"],
            commandArgs: ["%@"]
        )
    )

    static let alacritty = TerminalApp(
        id: "org.alacritty",
        name: "Alacritty",
        launch: .executable(
            path: "/Applications/Alacritty.app/Contents/MacOS/alacritty",
            workdirArgs: ["--working-directory", "%@"],
            commandArgs: ["-e", "%@"]
        )
    )
}
