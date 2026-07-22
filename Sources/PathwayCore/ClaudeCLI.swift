import Foundation

/// Определяет, установлен ли Claude Code CLI.
///
/// Найденный путь нужен только как признак «CLI есть» — в терминал уходит короткое
/// `claude`. Терминал стартует интерактивный shell со своим профилем, где PATH уже
/// собран правильно, и там разрешатся и обёртки, и версии из nvm, для которых
/// жёсткий путь оказался бы неверным.
public enum ClaudeCLI {
    /// Команда, которую набираем в терминале.
    public static let command = "claude"

    private nonisolated(unsafe) static var cached: String??

    /// Путь к claude, если он установлен. Результат кэшируется на время сессии:
    /// меню открывают часто, а обходить диск каждый раз незачем.
    public static func path() -> String? {
        if let cached { return cached }
        let found = locate(searchPaths: candidatePaths())
        cached = found
        return found
    }

    public static var isInstalled: Bool { path() != nil }

    /// Первый существующий исполняемый файл из списка.
    static func locate(searchPaths: [String]) -> String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Места, где может лежать claude.
    ///
    /// GUI-приложение наследует урезанный PATH (обычно /usr/bin:/bin:/usr/sbin:/sbin),
    /// в который не входят ни ~/.claude/local, ни Homebrew. Полагаться на PATH
    /// значит не найти CLI у большинства тех, у кого он стоит, поэтому основные
    /// места перечислены явно, а PATH идёт дополнением.
    static func candidatePaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = [
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude",
            "/usr/bin/claude",
        ]

        if let environmentPath = ProcessInfo.processInfo.environment["PATH"] {
            paths += environmentPath
                .split(separator: ":")
                .map { "\($0)/claude" }
        }

        // Порядок важен, поэтому не Set: убираем повторы, сохраняя первое вхождение.
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}
