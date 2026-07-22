import Foundation
import Observation

/// Глобальное состояние приложения: настройки и избранное.
///
/// Избранное живёт в FavoritesStore — он же хранит его между запусками.
@Observable
@MainActor
public final class AppState {
    public let favorites: FavoritesStore
    /// Действия над папкой, общие для сайдбара и списка файлов.
    public let folderActions: FolderActions
    public var showHiddenFiles: Bool = false

    public init(
        favorites: FavoritesStore = FavoritesStore(),
        terminal: TerminalLauncher = TerminalLauncher()
    ) {
        self.favorites = favorites
        self.folderActions = FolderActions(favorites: favorites, terminal: terminal)
    }
}
