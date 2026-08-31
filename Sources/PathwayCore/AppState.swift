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

    /// Поиск. Один на приложение, а не на вкладку: поиск — временный режим, из
    /// которого выходят по Esc или переходу в папку, а не состояние вкладки,
    /// которое стоит хранить. Общая модель заодно делит кэш оглавлений между
    /// вкладками — на сетевом диске это спасает от повторного чтения архивов.
    public let search = SearchModel()

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

    /// Сортировка списка — по тем же причинам в TabsModel: общая для всех
    /// вкладок и переживает перезапуск.
    public var sort: SortSettings {
        get { tabs.sort }
        set { tabs.sort = newValue }
    }

    /// Масштаб списка — там же и по тем же причинам: общий для всех вкладок и
    /// переживает перезапуск.
    public var scale: ListScale {
        get { tabs.scale }
        set { tabs.scale = newValue }
    }

    /// Доступны ли операции над репозиторием: цель найдена и он не занят.
    ///
    /// Цель — текущий репозиторий либо выделенная папка-репозиторий. Только
    /// текущего мало: в папке с проектами, которая сама репозиторием не
    /// является, все операции были бы мертвы — а это главный сценарий.
    public var isGitAvailable: Bool {
        !isEditingText && !browser.isBusy && browser.gitTarget != nil
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
    /// Элементы для листа пакетного переименования; nil — лист закрыт.
    public var pendingBatchRename: [FileItem]?
    /// Адресная строка должна перейти в режим ввода.
    public var pendingEditPath = false
    /// Поле поиска должно получить фокус.
    public var pendingSearch = false
    /// Папка, в которую клонируют репозиторий; nil — диалог закрыт.
    ///
    /// Клонирование требует диалога (адрес и имя папки), а Core диалогов не
    /// показывает — тот же обратный канал, что у pendingCompress.
    public var pendingClone: URL?
    /// Репозиторий, для которого открыт список веток. Обратный канал «Core
    /// просит UI»: команда выставляет запрос, лист его исполняет и сбрасывает.
    public var pendingBranchSwitch: URL?
    /// Субъект для диалога свойств; nil — диалог закрыт.
    public var pendingProperties: PropertiesSubject?
    /// Панель быстрого просмотра должна открыться.
    ///
    /// Флаг, а не список URL: панель забирает файлы из выделения сама в момент
    /// показа. Список пришлось бы поддерживать в актуальном состоянии при
    /// каждой смене выделения — панель следует за ним, пока открыта.
    public var pendingQuickLook = false

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
