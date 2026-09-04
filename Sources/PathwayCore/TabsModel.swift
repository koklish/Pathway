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

    /// Вкладка закреплена: не закрывается и стоит в начале полосы.
    ///
    /// internal(set), как и hasLoaded: флаг вправе менять только TabsModel —
    /// он следом чинит порядок и сохраняет сессию. Выставленный из вью, он
    /// оставил бы закреплённую вкладку посреди обычных.
    public internal(set) var isPinned = false

    init(
        path: URL,
        showHiddenFiles: Bool,
        sort: SortSettings,
        watcher: any DirectoryWatching,
        git: GitService,
        isPinned: Bool = false
    ) {
        browser = BrowserModel(path: path, watcher: watcher, git: git)
        browser.showHiddenFiles = showHiddenFiles
        // Сортировка задаётся до первой загрузки: выставленная после, она
        // заставила бы список перестроиться сразу после появления.
        browser.applySort(sort)
        self.isPinned = isPinned
    }

    /// Название для полосы вкладок. Вычисляемое, а не хранимое: путь меняется
    /// при каждой навигации, и хранимое поле пришлось бы синхронизировать руками.
    public var title: String {
        let path = browser.pane.path
        guard path.path != "/" else { return "Этот Мас" }
        return SystemFolderNames.displayNameAskingSystem(for: path)
    }

    /// Папка вкладки лежит на сетевом томе. Полоса вкладок рисует по этому
    /// признаку значок сервера: иначе шара и обычная папка выглядят одинаково,
    /// а название вроде «Спецификации» ничего о сервере не говорит.
    public var isOnNetworkVolume: Bool {
        // Спрашиваем файловую систему на каждое обращение, а не кэшируем при
        // навигации: том могли отключить мимо приложения, и запомненный признак
        // остался бы у вкладки, ведущей в никуда.
        (try? browser.pane.path.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
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

    /// Сортировка списка — тоже настройка приложения, а не папки: раздаётся
    /// всем вкладкам и достаётся вновь открытым. Хранится здесь, а не в
    /// BrowserModel: своя копия у каждой вкладки означала бы, что выбор
    /// пользователя действует только на текущей и теряется при открытии новой.
    ///
    /// Перечитывать папку не нужно — в отличие от showHiddenFiles сортировка
    /// меняет только порядок уже прочитанного списка, а не его состав.
    public var sort: SortSettings = .default {
        didSet {
            guard sort != oldValue else { return }
            for tab in tabs {
                tab.browser.applySort(sort)
            }
            store.save(sort: sort)
        }
    }

    /// Масштаб списка — настройка приложения, как и сортировка: один на все
    /// вкладки и на все папки. Два хранилища одного значения разошлись бы при
    /// первом открытии вкладки, как это было бы с showHiddenFiles.
    ///
    /// Вкладкам не раздаётся вовсе, в отличие от sort: масштаб не меняет ни
    /// состав списка, ни его порядок — только то, как список нарисован. Читает
    /// его напрямую вью, и BrowserModel о нём не знает.
    public var scale: ListScale = .default {
        didSet {
            guard scale != oldValue else { return }
            store.save(scale: scale)
        }
    }

    /// Ширины колонок, настроенные вручную, — настройка приложения, как
    /// сортировка и масштаб.
    ///
    /// Вкладкам не раздаётся, как и scale: ширина колонки — свойство того, как
    /// список нарисован, а не того, что в нём лежит. Пишется через
    /// setColumnWidth, а не присваиванием целиком: источник — перетаскивание
    /// одной колонки, и замена всего словаря на каждое движение мыши потеряла
    /// бы соседние записи, случись им обновиться параллельно.
    public private(set) var columnWidths: ColumnWidths = .default

    /// Запоминает ширину колонки, настроенную перетаскиванием.
    public func setColumnWidth(_ width: CGFloat, for column: String) {
        var updated = columnWidths
        updated.set(width, for: column)
        guard updated != columnWidths else { return }
        columnWidths = updated
        store.save(columnWidths: updated)
    }

    private let store: TabsStore
    private let fallback: URL
    /// Наблюдатель у каждой вкладки свой. Фабрика, а не готовый экземпляр:
    /// общий наблюдатель следил бы за одной папкой на всех, и переключение
    /// вкладок сбивало бы слежение фоновым.
    private let makeWatcher: () -> any DirectoryWatching
    private let git: GitService

    public init(
        path: URL = FileManager.default.homeDirectoryForCurrentUser,
        store: TabsStore = TabsStore(),
        makeWatcher: @escaping () -> any DirectoryWatching = { DirectoryWatcher() },
        git: GitService = GitService()
    ) {
        self.store = store
        self.fallback = path
        self.makeWatcher = makeWatcher
        self.git = git

        // Значение раздаётся вкладкам параметром конструктора, а не через
        // didSet: на этапе инициализации tabs ещё пуст, раздавать некому, — а
        // сам didSet записал бы в хранилище только что прочитанное оттуда.
        let restoredSort = store.restoreSort()
        sort = restoredSort
        // По той же причине, что и сортировка: didSet записал бы в хранилище
        // только что прочитанное оттуда.
        scale = store.restoreScale()
        columnWidths = store.restoreColumnWidths()

        let restored = store.restore()
        let items = restored.items.isEmpty ? [TabRecord(path: path)] : restored.items
        tabs = items.map {
            TabState(
                path: $0.path,
                showHiddenFiles: false,
                sort: restoredSort,
                watcher: makeWatcher(),
                git: git,
                isPinned: $0.isPinned
            )
        }
        // Порядок из хранилища мог разойтись с инвариантом: сессию мог записать
        // билд без закрепления, а пользователь — поправить plist руками.
        sortPinnedFirst()
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
    /// На закреплённой — тоже: иначе защита от закрытия была бы неполной, а
    /// частичной защите нельзя доверять, ради неё вкладку и закрепляли.
    public var canCloseActive: Bool { canClose(id: active.id) }

    /// Можно ли закрыть эту вкладку.
    public func canClose(id: UUID) -> Bool {
        guard tabs.count > 1, let tab = tabs.first(where: { $0.id == id }) else { return false }
        return !tab.isPinned
    }

    // MARK: - Закрепление

    /// Граница групп: индекс, на котором заканчиваются закреплённые вкладки.
    private var pinnedCount: Int {
        tabs.prefix { $0.isPinned }.count
    }

    /// Закрепляет вкладку и переносит её в конец закреплённой группы.
    public func pin(id: UUID) {
        setPinned(true, id: id)
    }

    /// Открепляет вкладку и переносит в начало обычной группы.
    public func unpin(id: UUID) {
        setPinned(false, id: id)
    }

    private func setPinned(_ pinned: Bool, id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].isPinned != pinned else { return }
        let activeID = active.id
        let tab = tabs.remove(at: index)
        tab.isPinned = pinned
        // И закрепление, и открепление кладут вкладку на границу групп: она же
        // конец закреплённых и начало обычных. После удаления вкладки из списка
        // граница уже посчитана без неё, поэтому вставка идёт ровно на неё.
        tabs.insert(tab, at: pinnedCount)
        // Активной остаётся та же вкладка, а не та же позиция.
        activeIndex = tabs.firstIndex { $0.id == activeID } ?? activeIndex
        save()
    }

    /// Приводит список к инварианту «закреплённые в начале», сохраняя порядок
    /// внутри каждой группы.
    private func sortPinnedFirst() {
        let activeID = tabs.indices.contains(activeIndex) ? tabs[activeIndex].id : nil
        // Стабильная разбивка вместо sort: сортировка по Bool в Swift порядок
        // равных элементов не гарантирует, и вкладки внутри группы
        // перемешивались бы на каждом запуске.
        tabs = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
        if let activeID, let index = tabs.firstIndex(where: { $0.id == activeID }) {
            activeIndex = index
        }
    }

    // MARK: - Открытие

    /// Открывает папку новой вкладкой справа от активной — а не в конце списка:
    /// вкладка должна появляться рядом с той, из которой её открыли.
    public func open(_ url: URL, activate: Bool = true) {
        let tab = TabState(
            path: url,
            showHiddenFiles: showHiddenFiles,
            sort: sort,
            watcher: makeWatcher(),
            git: git
        )
        watch(tab)
        // Справа от активной, но не внутрь закреплённой группы: открытая из
        // закреплённой вкладки, новая иначе встала бы между закреплёнными и
        // порвала инвариант.
        let index = max(activeIndex + 1, pinnedCount)
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
        guard canClose(id: id), let index = tabs.firstIndex(where: { $0.id == id }) else { return }
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
        guard tabs.contains(where: { $0.id == id }) else { return }
        // Закреплённые остаются: закрепление затем и нужно, чтобы групповое
        // закрытие их не трогало.
        let survives = { (tab: TabState) in tab.id == id || tab.isPinned }
        for tab in tabs where !survives(tab) {
            tab.browser.cancelLoad()
        }
        tabs = tabs.filter(survives)
        sortPinnedFirst()
        activeIndex = tabs.firstIndex { $0.id == id } ?? 0
        // Оставленная вкладка могла быть фоновой и папку ещё не читать.
        let wasLoaded = active.hasLoaded
        loadIfNeeded(active)
        updateWatching()
        if wasLoaded { active.browser.refreshAfterReturn() }
        save()
    }

    public func closeToTheRight(of id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), index < tabs.count - 1 else { return }
        let activeID = active.id
        // Закреплённые справа остаются. Существенно именно на закреплённой
        // вкладке: правее неё лежат остальные закреплённые, и удаление
        // диапазоном снесло бы ровно то, что закрепление защищает.
        let doomed = tabs[(index + 1)...].filter { !$0.isPinned }
        guard !doomed.isEmpty else { return }
        let doomedIDs = Set(doomed.map(\.id))
        for tab in doomed {
            tab.browser.cancelLoad()
        }
        tabs.removeAll { doomedIDs.contains($0.id) }
        // Активная могла оказаться среди закрытых — тогда ею становится
        // указанная вкладка, а она могла быть фоновой и папку не читать.
        let wasActiveClosed = doomedIDs.contains(activeID)
        activeIndex = wasActiveClosed
            ? (tabs.firstIndex { $0.id == id } ?? tabs.count - 1)
            : (tabs.firstIndex { $0.id == activeID } ?? 0)
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
        // Перетаскивание не переносит вкладку через границу групп: закреплённая
        // уехала бы в середину полосы, а после перезапуска перескочила обратно —
        // порядок на экране разошёлся бы с сохранённым.
        let pinned = pinnedCount
        let allowed = tabs[source].isPinned ? 0..<pinned : pinned..<tabs.count
        let target = min(max(destination, allowed.lowerBound), allowed.upperBound - 1)
        guard target != source else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: target)
        // Активной остаётся та же вкладка, а не та же позиция.
        activeIndex = tabs.firstIndex { $0.id == active } ?? activeIndex
        save()
    }

    // MARK: - Сохранение

    /// Вызывается вью при смене папки в любой вкладке: путь меняется мимо
    /// TabsModel, через сам BrowserModel, и заметить это отсюда нечем.
    public func save() {
        store.save(
            items: tabs.map { TabRecord(path: $0.browser.pane.path, isPinned: $0.isPinned) },
            activeIndex: activeIndex
        )
    }
}
