import Foundation
import Observation

/// Одна вкладка: собственная папка, история, выделение и кэш.
///
/// Владеет своим BrowserModel — отсюда независимость вкладок достаётся даром,
/// без единой строки кода: она уже заложена в разделении BrowserModel/PaneState.
@Observable
@MainActor
public final class TabState: Identifiable {
    public let id = UUID()
    public let browser: BrowserModel

    /// Папку этой вкладки уже читали. Отдельный флаг, а не проверка на пустой
    /// список: пустая папка тоже даёт пустой items, и без флага такая вкладка
    /// обходила бы каталог заново на каждое переключение.
    public internal(set) var hasLoaded = false

    init(path: URL, showHiddenFiles: Bool, watcher: any DirectoryWatching) {
        browser = BrowserModel(path: path, watcher: watcher)
        browser.showHiddenFiles = showHiddenFiles
    }

    /// Название для полосы вкладок. Вычисляемое, а не хранимое: путь меняется
    /// при каждой навигации, и хранимое поле пришлось бы синхронизировать руками.
    public var title: String {
        let path = browser.pane.path
        guard path.path != "/" else { return "Этот Мас" }
        return SystemFolderNames.displayNameAskingSystem(for: path)
    }
}

/// Список вкладок с активной. Держит инварианты: список не пуст, индекс
/// всегда валиден, закрытие активной переводит фокус на соседку.
@Observable
@MainActor
public final class TabsModel {
    public private(set) var tabs: [TabState] = []
    public private(set) var activeIndex: Int = 0

    /// Показ скрытых файлов — настройка приложения, а не папки: раздаётся
    /// всем вкладкам сразу и достаётся вновь открытым.
    public var showHiddenFiles = false {
        didSet {
            guard showHiddenFiles != oldValue else { return }
            for tab in tabs {
                tab.browser.showHiddenFiles = showHiddenFiles
                // Перечитываем только показанные вкладки: непрочитанная и так
                // возьмёт новое значение при первом показе, а обход каталога
                // ради невидимого списка стоил бы на сетевом диске секунд.
                if tab.hasLoaded {
                    tab.browser.reloadAsync()
                }
            }
        }
    }

    private let store: TabsStore
    private let fallback: URL
    /// Наблюдатель у каждой вкладки свой. Фабрика, а не готовый экземпляр:
    /// общий наблюдатель следил бы за одной папкой на всех, и переключение
    /// вкладок сбивало бы слежение фоновым.
    private let makeWatcher: () -> any DirectoryWatching

    public init(
        path: URL = FileManager.default.homeDirectoryForCurrentUser,
        store: TabsStore = TabsStore(),
        makeWatcher: @escaping () -> any DirectoryWatching = { DirectoryWatcher() }
    ) {
        self.store = store
        self.fallback = path
        self.makeWatcher = makeWatcher

        let restored = store.restore()
        let paths = restored.paths.isEmpty ? [path] : restored.paths
        tabs = paths.map { TabState(path: $0, showHiddenFiles: false, watcher: makeWatcher()) }
        // Индекс мог указывать на вкладку, которая не уцелела.
        activeIndex = min(max(restored.activeIndex, 0), tabs.count - 1)
        tabs.forEach(watch)
    }

    /// Подписывает вкладку на смену папки, чтобы сессия сохранялась сама.
    /// Полагаться на вызов save() из вью нельзя: место, забывшее его позвать,
    /// молча теряло бы последний путь.
    private func watch(_ tab: TabState) {
        tab.browser.didChangeFolder = { [weak self] in self?.save() }
    }

    public var active: TabState { tabs[activeIndex] }

    /// ⌘W гасится на единственной вкладке: у приложения одно окно, и закрывать
    /// его этой командой значило бы оставить пользователя с пустым Dock-значком.
    public var canCloseActive: Bool { tabs.count > 1 }

    // MARK: - Открытие

    /// Открывает папку новой вкладкой справа от активной — а не в конце списка:
    /// вкладка должна появляться рядом с той, из которой её открыли.
    public func open(_ url: URL, activate: Bool = true) {
        let tab = TabState(path: url, showHiddenFiles: showHiddenFiles, watcher: makeWatcher())
        watch(tab)
        let index = activeIndex + 1
        tabs.insert(tab, at: index)
        if activate {
            activeIndex = index
            loadIfNeeded(tab)
            updateWatching()
        }
        save()
    }

    // MARK: - Закрытие

    public func closeActive() {
        close(id: active.id)
    }

    public func close(id: UUID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        // Загрузку снимаем явно: loadTask держит модель сильной ссылкой через
        // захват в замыкании, и незавершённое чтение сетевой папки продержало бы
        // закрытую вкладку в памяти до своего конца.
        tabs[index].browser.cancelLoad()
        let wasActive = index == activeIndex
        tabs.remove(at: index)

        if wasActive {
            // Правая соседка, а если её нет — левая.
            activeIndex = min(index, tabs.count - 1)
            let wasLoaded = active.hasLoaded
            loadIfNeeded(active)
            updateWatching()
            if wasLoaded { active.browser.refreshAfterReturn() }
        } else if index < activeIndex {
            // Активной остаётся та же вкладка, а не тот же индекс.
            activeIndex -= 1
        }
        save()
    }

    public func closeOthers(id: UUID) {
        guard let kept = tabs.first(where: { $0.id == id }) else { return }
        for tab in tabs where tab.id != id {
            tab.browser.cancelLoad()
        }
        tabs = [kept]
        activeIndex = 0
        // Оставленная вкладка могла быть фоновой и папку ещё не читать.
        let wasLoaded = active.hasLoaded
        loadIfNeeded(active)
        updateWatching()
        if wasLoaded { active.browser.refreshAfterReturn() }
        save()
    }

    public func closeToTheRight(of id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), index < tabs.count - 1 else { return }
        for tab in tabs[(index + 1)...] {
            tab.browser.cancelLoad()
        }
        tabs.removeSubrange((index + 1)...)
        // Активная могла оказаться среди закрытых — тогда ею становится
        // указанная вкладка, а она могла быть фоновой и папку не читать.
        let wasActiveClosed = activeIndex > index
        activeIndex = min(activeIndex, tabs.count - 1)
        if wasActiveClosed {
            let wasLoaded = active.hasLoaded
            loadIfNeeded(active)
            if wasLoaded { active.browser.refreshAfterReturn() }
        }
        updateWatching()
        save()
    }

    // MARK: - Переключение и порядок

    public func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        let changed = activeIndex != index
        activeIndex = index
        let wasLoaded = active.hasLoaded
        loadIfNeeded(active)
        updateWatching()
        // Пока вкладка была фоновой, слежения за ней не велось, и папка могла
        // измениться. Только для уже прочитанной: непрочитанную читает
        // loadIfNeeded, и второе обновление поверх было бы лишним обходом.
        if changed, wasLoaded {
            active.browser.refreshAfterReturn()
        }
        save()
    }

    /// Читает папку вкладки, если та ещё ни разу не показывалась.
    ///
    /// Восстановленные и фоновые вкладки создаются, но каталог не трогают:
    /// открытие десяти вкладок на сетевом диске иначе стоило бы десяти обходов
    /// сразу. Возврат на уже прочитанную вкладку список не перечитывает — он
    /// должен появиться мгновенно, ради этого вкладки и заводились.
    private func loadIfNeeded(_ tab: TabState) {
        guard !tab.hasLoaded else { return }
        tab.hasLoaded = true
        tab.browser.reloadAsync()
    }

    /// Загружает активную вкладку при первом показе окна.
    public func loadActive() {
        loadIfNeeded(active)
        updateWatching()
    }

    /// Оставляет слежение ровно у активной вкладки.
    ///
    /// Следить за всеми открытыми значило бы держать по потоку FSEvents на
    /// вкладку: десять вкладок на сетевом диске — десять соединений к серверу.
    /// Фоновая вкладка вместо этого обновляется при возврате: пока её не видно,
    /// расхождение списка с диском никого не беспокоит.
    private func updateWatching() {
        for (index, tab) in tabs.enumerated() where index != activeIndex {
            tab.browser.stopWatching()
        }
        // Непрочитанной вкладке слежение поставит сама загрузка, по готовому
        // списку: событие на недочитанную папку дало бы дифф против неполного
        // списка.
        guard active.hasLoaded else { return }
        active.browser.resumeWatching()
    }

    public func select(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        select(index: index)
    }

    /// По кругу: на последней вкладке ⌃⇥ возвращает к первой. Так ведут себя
    /// Safari и Терминал, а упор в край выглядел бы поломкой.
    public func selectNext() {
        select(index: (activeIndex + 1) % tabs.count)
    }

    public func selectPrevious() {
        select(index: (activeIndex - 1 + tabs.count) % tabs.count)
    }

    public func move(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source), tabs.indices.contains(destination), source != destination else { return }
        let active = tabs[activeIndex].id
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: destination)
        // Активной остаётся та же вкладка, а не та же позиция.
        activeIndex = tabs.firstIndex { $0.id == active } ?? activeIndex
        save()
    }

    // MARK: - Сохранение

    /// Вызывается вью при смене папки в любой вкладке: путь меняется мимо
    /// TabsModel, через сам BrowserModel, и заметить это отсюда нечем.
    public func save() {
        store.save(paths: tabs.map(\.browser.pane.path), activeIndex: activeIndex)
    }
}
