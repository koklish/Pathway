import Foundation
import Observation

/// Глобальное состояние приложения: панель, настройки и избранное.
///
/// Панель живёт здесь, а не во вью, потому что до неё должны дотягиваться
/// команды главного меню: `.commands` строится в App и не видит @State окна.
/// При переходе на две панели это свойство станет «активной панелью».
@Observable
@MainActor
public final class AppState {
    public let browser: BrowserModel
    public let favorites: FavoritesStore
    /// Действия над папкой, общие для сайдбара и списка файлов.
    public let folderActions: FolderActions
    /// Обучающий тур: первый запуск и повторный запуск кнопкой «?».
    public let onboarding: OnboardingModel
    /// Приложения, найденные при запуске: от них зависит состав подменю
    /// «Создать». Опрос разовый — см. InstalledApps.
    public let appLookup: any AppLookup
    public var showHiddenFiles: Bool = false

    /// Идёт ввод текста — переименование, адресная строка или поле в диалоге.
    /// Файловые команды на это время гасятся: F2, ⌘⌫ и ⌘⇧N текстовое поле
    /// не перехватывает само, в отличие от ⌘C/⌘X/⌘V.
    public var isEditingText = false

    // MARK: - Запросы к интерфейсу
    //
    // Команды, которым нужен UI (диалог, инлайн-редактор, фокус поля), не могут
    // выполниться внутри PathwayCore. Они выставляют запрос, вью его исполняет
    // и сбрасывает обратно.

    /// Элемент, для которого нужно начать инлайн-переименование.
    public var pendingRename: URL?
    /// Элементы для диалога архивации; nil — диалог закрыт.
    public var pendingCompress: [FileItem]?
    /// Адресная строка должна перейти в режим ввода.
    public var pendingEditPath = false

    public init(
        path: URL = FileManager.default.homeDirectoryForCurrentUser,
        favorites: FavoritesStore = FavoritesStore(),
        terminal: TerminalLauncher = TerminalLauncher(),
        onboarding: OnboardingModel = OnboardingModel(),
        appLookup: any AppLookup = InstalledApps()
    ) {
        self.browser = BrowserModel(path: path)
        self.favorites = favorites
        self.folderActions = FolderActions(favorites: favorites, terminal: terminal)
        self.onboarding = onboarding
        self.appLookup = appLookup
    }
}
