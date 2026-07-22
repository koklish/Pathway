import Foundation
import Testing

@testable import PathwayCore

@Suite("Запуск терминала")
@MainActor
struct TerminalLauncherTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "terminal.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private let folder = URL(fileURLWithPath: "/Users/tester/Projects")

    // MARK: - Экранирование AppleScript

    @Test("кавычки и слэши в пути экранируются для AppleScript")
    func escapesQuotesAndBackslashes() {
        let escaped = TerminalLauncher.escapeForAppleScript(#"/tmp/a "b"/c\d"#)

        #expect(escaped == #"/tmp/a \"b\"/c\\d"#)
    }

    @Test("обратный слэш экранируется раньше кавычек")
    func escapesBackslashBeforeQuote() {
        // Если порядок перепутать, \" превратится в \\" и строка разъедется.
        let escaped = TerminalLauncher.escapeForAppleScript(#"a\"b"#)

        #expect(escaped == #"a\\\"b"#)
    }

    @Test("апостроф и пробелы для AppleScript не экранируются")
    func leavesApostropheAlone() {
        let escaped = TerminalLauncher.escapeForAppleScript("/tmp/Ваня's папка")

        #expect(escaped == "/tmp/Ваня's папка")
    }

    @Test("перевод строки в пути не разрывает скрипт")
    func escapesNewline() {
        let escaped = TerminalLauncher.escapeForAppleScript("/tmp/a\nb")

        #expect(!escaped.contains("\n"))
    }

    // MARK: - Экранирование для shell

    @Test("путь для shell берётся в одинарные кавычки")
    func quotesPathForShell() {
        #expect(TerminalLauncher.quoteForShell("/tmp/my folder") == "'/tmp/my folder'")
    }

    @Test("апостроф внутри пути не ломает shell-кавычки")
    func quotesApostropheForShell() {
        // 'Ваня'\''s' — стандартный приём закрыть кавычку, вставить \' и открыть снова.
        #expect(TerminalLauncher.quoteForShell("/tmp/Ваня's") == #"'/tmp/Ваня'\''s'"#)
    }

    // MARK: - Выбор терминала

    @Test("без настройки берётся первый доступный терминал")
    func picksFirstAvailableByDefault() {
        let launcher = TerminalLauncher(defaults: makeDefaults(), available: [.terminalApp, .iTerm2])

        #expect(launcher.preferred.id == TerminalApp.terminalApp.id)
    }

    @Test("сохранённый выбор пользователя имеет приоритет")
    func honoursStoredPreference() {
        let defaults = makeDefaults()
        let launcher = TerminalLauncher(defaults: defaults, available: [.terminalApp, .iTerm2])

        launcher.select(.iTerm2)

        let reopened = TerminalLauncher(defaults: defaults, available: [.terminalApp, .iTerm2])
        #expect(reopened.preferred.id == TerminalApp.iTerm2.id)
    }

    @Test("исчезнувший терминал заменяется доступным")
    func fallsBackWhenPreferredIsGone() {
        let defaults = makeDefaults()
        TerminalLauncher(defaults: defaults, available: [.terminalApp, .iTerm2]).select(.iTerm2)

        // iTerm2 удалили — остался только системный терминал.
        let launcher = TerminalLauncher(defaults: defaults, available: [.terminalApp])

        #expect(launcher.preferred.id == TerminalApp.terminalApp.id)
    }

    @Test("при пустом списке доступных остаётся системный терминал")
    func alwaysHasTerminalApp() {
        let launcher = TerminalLauncher(defaults: makeDefaults(), available: [])

        #expect(launcher.preferred.id == TerminalApp.terminalApp.id)
    }

    // MARK: - Что именно запускается

    @Test("для терминала с аргументами путь уходит отдельным аргументом")
    func passesPathAsSeparateArgument() throws {
        let spy = LaunchSpy()
        let ghostty = TerminalApp(
            id: "com.mitchellh.ghostty",
            name: "Ghostty",
            launch: .executable(
                path: "/opt/homebrew/bin/ghostty",
                workdirArgs: ["--working-directory=%@"],
                commandArgs: ["-e", "%@"]
            )
        )
        let launcher = TerminalLauncher(defaults: makeDefaults(), available: [ghostty], runner: spy)

        try launcher.openTerminal(at: URL(fileURLWithPath: "/tmp/my folder"))

        #expect(spy.executablePath == "/opt/homebrew/bin/ghostty")
        // Путь не склеен с другими аргументами и не закавычен — shell тут не участвует.
        #expect(spy.arguments == ["--working-directory=/tmp/my folder"])
    }

    @Test("команда передаётся терминалу с аргументами без участия shell")
    func passesCommandAsArgument() throws {
        let spy = LaunchSpy()
        let kitty = TerminalApp(
            id: "net.kovidgoyal.kitty",
            name: "kitty",
            launch: .executable(
                path: "/opt/homebrew/bin/kitty",
                workdirArgs: ["--directory", "%@"],
                commandArgs: ["%@"]
            )
        )
        let launcher = TerminalLauncher(defaults: makeDefaults(), available: [kitty], runner: spy)

        try launcher.runCommand("claude", at: folder)

        #expect(spy.arguments == ["--directory", folder.path, "claude"])
    }

    @Test("AppleScript-терминал получает скрипт с экранированным путём")
    func buildsAppleScriptWithEscapedPath() throws {
        let spy = LaunchSpy()
        let launcher = TerminalLauncher(defaults: makeDefaults(), available: [.terminalApp], runner: spy)

        try launcher.openTerminal(at: URL(fileURLWithPath: #"/tmp/a "b""#))

        let script = try #require(spy.script)
        #expect(script.contains(#"\"b\""#))
        #expect(script.contains("Terminal"))
    }

    @Test("запуск команды через AppleScript закавычивает путь для shell")
    func appleScriptCommandQuotesPath() throws {
        let spy = LaunchSpy()
        let launcher = TerminalLauncher(defaults: makeDefaults(), available: [.terminalApp], runner: spy)

        try launcher.runCommand("claude", at: URL(fileURLWithPath: "/tmp/my folder"))

        let script = try #require(spy.script)
        #expect(script.contains("cd '/tmp/my folder'"))
        #expect(script.contains("claude"))
    }

    /// Путь проходит два экранирования подряд — shell и AppleScript,
    /// поэтому проверяем именно их совместный результат, а не каждое по отдельности.
    /// Ожидаемая строка снята с реального запуска: Терминал по ней переходит
    /// ровно в «/tmp/тест папка's».
    @Test("апостроф в пути переживает оба уровня экранирования")
    func survivesShellAndAppleScriptEscaping() {
        let shellLine = "cd \(TerminalLauncher.quoteForShell("/tmp/тест папка's"))"

        let script = TerminalLauncher.escapeForAppleScript(shellLine)

        #expect(script == #"cd '/tmp/тест папка'\\''s'"#)
    }

    @Test("двойные кавычки в пути не разрывают do script")
    func doubleQuotesSurviveBothLayers() {
        let shellLine = "cd \(TerminalLauncher.quoteForShell(#"/tmp/a "b""#))"

        let script = TerminalLauncher.escapeForAppleScript(shellLine)

        // Кавычки экранированы — литерал do script остаётся целым.
        #expect(script == #"cd '/tmp/a \"b\"'"#)
    }

    @Test("ошибка запуска долетает до вызывающего")
    func propagatesLaunchFailure() {
        let spy = LaunchSpy()
        spy.error = TerminalError.launchFailed("Ghostty", "нет доступа")
        let launcher = TerminalLauncher(defaults: makeDefaults(), available: [.terminalApp], runner: spy)

        #expect(throws: TerminalError.self) {
            try launcher.openTerminal(at: self.folder)
        }
    }
}

/// Подставной запускающий: записывает, что было бы выполнено, и ничего не запускает.
@MainActor
private final class LaunchSpy: TerminalRunning {
    var executablePath: String?
    var arguments: [String]?
    var script: String?
    var error: (any Error)?

    func run(executable: String, arguments: [String]) throws {
        executablePath = executable
        self.arguments = arguments
        if let error { throw error }
    }

    func runAppleScript(_ source: String) throws {
        script = source
        if let error { throw error }
    }
}
