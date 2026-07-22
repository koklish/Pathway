import AppKit
import Foundation
import Observation

/// Действия над папкой, общие для списка файлов и сайдбара:
/// избранное, терминал, Claude Code, показ в Finder.
///
/// Живёт отдельно от вью, потому что обе они вызывают одно и то же, а ошибки
/// должны показываться одинаково независимо от того, откуда пришёл вызов.
@Observable
@MainActor
public final class FolderActions {
    public let favorites: FavoritesStore
    public let terminal: TerminalLauncher
    /// Текст последней ошибки — вью показывает его алертом.
    public var errorMessage: String?

    public init(favorites: FavoritesStore, terminal: TerminalLauncher) {
        self.favorites = favorites
        self.terminal = terminal
    }

    // MARK: - Избранное

    public func isFavorite(_ url: URL) -> Bool {
        favorites.contains(url)
    }

    public func toggleFavorite(_ url: URL) {
        if favorites.contains(url) {
            favorites.remove(url: url)
        } else {
            favorites.add(url)
        }
    }

    // MARK: - Терминал

    public var isClaudeAvailable: Bool { ClaudeCLI.isInstalled }

    public var terminalName: String { terminal.preferred.name }

    public func openTerminal(at folder: URL) {
        perform { try terminal.openTerminal(at: folder) }
    }

    public func openClaude(at folder: URL) {
        perform { try terminal.runCommand(ClaudeCLI.command, at: folder) }
    }

    // MARK: - Finder

    public func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func perform(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
