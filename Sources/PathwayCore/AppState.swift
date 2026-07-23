import Foundation
import Observation

/// Глобальное состояние приложения: вкладки, настройки и избранное.
///
/// Вкладки живут здесь, а не во вью, потому что до активной панели должны
/// дотягиваться команды главного меню: `.commands` строится в App и не видит
/// @State окна.
@Observable
@MainActor
public final class AppState {
    /// Открытые вкладки. Активная и есть панель, с которой работают команды.
    public let tabs: TabsModel
    public let favorites: FavoritesStore
    /// Действия над папкой, общие для сайдбара и списка файлов.
    public let folderActions: FolderActions
    /// Обучающий тур: первый запуск и повторный запуск кнопкой «?».
    public let onboarding: OnboardingModel

    /// Активная вкладка. Свойство сохранено намеренно: до перехода на вкладки
    /// здесь жила единственная панель, и весь реестр команд, сайдбар и список
    /// файлов обращаются к модели через него. Замена на `tabs.active.browser`
    /// в каждом месте ничего не улучшила бы, а правок потребовала бы в двух
    /// десятках файлов.
    public var browser: BrowserModel { tabs.active.browser }

    /// Настройка приложения, а не папки: значение раздаётся всем вкладкам.
    /// Хранится в TabsModel, чтобы не заводить второй источник правды —
    /// вновь открытая вкладка должна получить текущее значение сама.
    public var showHiddenFiles: Bool {
        get { tabs.showHiddenFiles }
        set { tabs.showHiddenFiles = newValue }
    }

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
        tabs: TabsModel? = nil,
        favorites: FavoritesStore = FavoritesStore(),
        terminal: TerminalLauncher = TerminalLauncher(),
        onboarding: OnboardingModel = OnboardingModel()
    ) {
        self.tabs = tabs ?? TabsModel(path: path)
        self.favorites = favorites
        self.folderActions = FolderActions(favorites: favorites, terminal: terminal)
        self.onboarding = onboarding
    }
}
