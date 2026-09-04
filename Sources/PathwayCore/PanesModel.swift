import Foundation
import Observation

/// Сторона сплита. Две, а не произвольное число: третья панель в файловом
/// менеджере не встречается, а список вместо пары заставил бы каждое место
/// спрашивать «а сколько их сейчас» вместо обращения по имени.
public enum PaneGroup: String, CaseIterable, Sendable {
    case left
    case right

    /// Суффикс ключей в сессии. Отдельно от rawValue: rawValue участвует ещё и
    /// в сравнениях по коду, и переименование стороны молча сменило бы формат
    /// хранения, потеряв людям вкладки.
    var storageSuffix: String { rawValue }

    public var other: PaneGroup { self == .left ? .right : .left }
}

/// Две группы вкладок и признак, какая из них активна.
///
/// Каждая группа — самостоятельный `TabsModel` со своей полосой вкладок, своим
/// закреплением и своей активной вкладкой. Групповая логика живёт здесь, а не
/// внутри `TabsModel`: тот описывает поведение одной полосы — порядок
/// закреплённых, ленивую загрузку, слежение за папкой, — и все эти инварианты
/// одинаковы независимо от того, сколько полос на экране. Разложи их по
/// группам внутри самого `TabsModel`, каждый его метод получил бы параметр
/// «в какой группе», а проверять пришлось бы заново всё, что уже проверено.
@Observable
@MainActor
public final class PanesModel {
    /// Левая существует всегда: сплит — это появление правой, а не деление
    /// единственной панели надвое. Иначе выключение сплита требовало бы решать,
    /// какая из половин остаётся.
    public let left: TabsModel
    /// Правая появляется при включении сплита и исчезает при выключении.
    /// Опционал, а не пустой `TabsModel`: группа без единой вкладки нарушила бы
    /// инвариант «список не пуст», на который опирается весь `TabsModel`.
    public private(set) var right: TabsModel?

    /// Группа, которой адресованы команды и клавиатура.
    public private(set) var activeGroup: PaneGroup = .left

    /// Показан ли сплит. Вычисляемое: второго источника правды о том же факте
    /// не заводим — флаг и наличие правой группы разошлись бы, и одна половина
    /// приложения считала бы сплит открытым, а другая закрытым.
    public var isSplit: Bool { right != nil }

    private let defaults: UserDefaults
    private let makeWatcher: () -> any DirectoryWatching
    private let git: GitService
    private let fallback: URL
    private let splitKey = "panes.isSplit"

    /// `left` принимается готовой ради тестов и ради `AppState(tabs:)`: там
    /// модель собирается на временной папке со своим UserDefaults, и собранная
    /// заново здесь ушла бы читать настоящую сессию пользователя.
    public init(
        path: URL = FileManager.default.homeDirectoryForCurrentUser,
        left: TabsModel? = nil,
        defaults: UserDefaults = .standard,
        makeWatcher: @escaping () -> any DirectoryWatching = { DirectoryWatcher() },
        git: GitService = GitService()
    ) {
        self.defaults = defaults
        self.makeWatcher = makeWatcher
        self.git = git
        self.fallback = path

        self.left = left ?? TabsModel(
            path: path,
            store: TabsStore(defaults: defaults, group: .left),
            makeWatcher: makeWatcher,
            git: git
        )

        // Правая восстанавливается, только если сплит был включён на момент
        // выхода: её сессия живёт, пока жив сплит. Выключенный сплит состава
        // не хранит — его вкладки при выключении переезжают в левую группу.
        //
        // Готовая левая отменяет восстановление: её принесли с собственным
        // хранилищем, и правая, собранная из переданных defaults, читала бы
        // чужую сессию — в тестах это настоящая сессия пользователя.
        if left == nil, defaults.bool(forKey: splitKey) {
            right = TabsModel(
                path: path,
                store: TabsStore(defaults: defaults, group: .right),
                makeWatcher: makeWatcher,
                git: git
            )
        }
    }

    /// Группы в порядке слева направо. Правая может отсутствовать, поэтому
    /// перебор идёт через этот массив, а не по `PaneGroup.allCases`.
    public var groups: [TabsModel] {
        [left, right].compactMap { $0 }
    }

    /// Модель вкладок указанной стороны; nil для правой, когда сплита нет.
    public func tabs(_ group: PaneGroup) -> TabsModel? {
        group == .left ? left : right
    }

    /// Активная группа вкладок. Через неё ходят реестр команд и `AppState`.
    public var active: TabsModel {
        // Правая могла исчезнуть вместе со сплитом, а признак остаться:
        // выключение сплита обязано вернуть фокус налево, и левая — то
        // единственное, что существует всегда.
        tabs(activeGroup) ?? left
    }

    // MARK: - Фокус

    /// Делает группу активной. Загружает её вкладку, если та ещё не читалась:
    /// правая группа после включения сплита создана, но каталог не трогала.
    public func focus(_ group: PaneGroup) {
        guard let tabs = tabs(group), activeGroup != group else { return }
        activeGroup = group
        tabs.loadActive()
    }

    /// Переносит фокус на другую сторону — ⇥ между панелями. Без сплита ничего
    /// не делает: перебрасывать фокус некуда, а молчаливый переход на
    /// несуществующую панель обернулся бы командой, ушедшей в никуда.
    public func focusOther() {
        guard isSplit else { return }
        focus(activeGroup.other)
    }

    // MARK: - Сплит

    /// Включает сплит, открывая правую группу на папке активной вкладки.
    ///
    /// Именно на текущей папке, а не на домашней: сплит включают, чтобы
    /// перенести файлы из того места, где человек уже стоит, и домашняя папка
    /// справа заставила бы дойти до нужной заново.
    public func openSplit() {
        guard right == nil else { return }
        let start = left.active.browser.pane.path
        let tabs = TabsModel(
            path: start,
            store: TabsStore(defaults: defaults, group: .right),
            makeWatcher: makeWatcher,
            git: git
        )
        tabs.showHiddenFiles = left.showHiddenFiles
        tabs.sort = left.sort
        right = tabs
        defaults.set(true, forKey: splitKey)
        // Фокус уходит вправо: включивший сплит собирается работать в новой
        // панели, а не в той, что и так была под руками.
        activeGroup = .right
        tabs.loadActive()
    }

    /// Выключает сплит. Вкладки правой группы не закрываются, а переезжают в
    /// левую: выключение сплита — про разметку экрана, а не про то, что человек
    /// закончил работу с этими папками.
    public func closeSplit() {
        guard let closing = right else { return }
        // Перевозим вместе с моделями, как при перетаскивании между панелями:
        // заново открытые по пути вкладки потеряли бы историю навигации,
        // выделение и уже прочитанный список.
        for tab in closing.tabs {
            left.adopt(tab)
        }
        right = nil
        defaults.set(false, forKey: splitKey)
        // Сессия правой группы стирается: её состав уехал в левую и уже записан
        // её хранилищем, а оставленная копия при следующем включении сплита
        // воскресила бы те же вкладки второй раз.
        TabsStore(defaults: defaults, group: .right).clear()
        activeGroup = .left
        // Заодно возвращает слежение к инварианту «следит только активная»:
        // активная вкладка правой группы следила за своей папкой, а в левой
        // стала фоновой — updateWatching внутри снимает с неё наблюдателя.
        left.loadActive()
    }

    public func toggleSplit() {
        isSplit ? closeSplit() : openSplit()
    }

    // MARK: - Настройки, общие для групп

    /// Показ скрытых файлов — настройка приложения, а не группы: раздаётся
    /// обеим сразу. Своя копия у каждой означала бы, что ⌘⇧. действует на
    /// половину экрана.
    public var showHiddenFiles: Bool {
        get { left.showHiddenFiles }
        set { groups.forEach { $0.showHiddenFiles = newValue } }
    }

    /// Сортировка — по той же причине общая для обеих групп.
    public var sort: SortSettings {
        get { left.sort }
        set { groups.forEach { $0.sort = newValue } }
    }

    /// Масштаб списка — общий: он описывает то, как список нарисован, и разный
    /// в двух половинах окна выглядел бы поломкой, а не настройкой.
    public var scale: ListScale {
        get { left.scale }
        set { groups.forEach { $0.scale = newValue } }
    }

    /// Ширины колонок — общие по той же причине, что и масштаб.
    public var columnWidths: ColumnWidths { left.columnWidths }

    public func setColumnWidth(_ width: CGFloat, for column: String) {
        groups.forEach { $0.setColumnWidth(width, for: column) }
    }

    /// Загружает активные вкладки обеих групп при первом показе окна.
    public func loadActive() {
        groups.forEach { $0.loadActive() }
    }

    // MARK: - Перенос вкладки между группами

    /// Переносит вкладку в другую группу — перетаскиванием из полосы в полосу.
    ///
    /// Вкладка перевозится вместе со своим `BrowserModel`, а не открывается
    /// заново по пути: иначе потерялись бы история навигации, выделение и уже
    /// прочитанный список, и перенос на сетевой папке стоил бы полного обхода.
    @discardableResult
    public func moveTab(id: UUID, from source: PaneGroup, to target: PaneGroup, at index: Int? = nil) -> Bool {
        guard source != target,
              let from = tabs(source),
              let to = tabs(target),
              let tab = from.tabs.first(where: { $0.id == id })
        else { return false }

        // Последнюю вкладку не отдаём: группа без вкладок нарушила бы инвариант
        // «список не пуст». Перенести всё содержимое группы — это выключить
        // сплит, и делается оно своей командой.
        guard from.tabs.count > 1 else { return false }

        from.detach(id: id)
        to.adopt(tab, at: index)
        // Фокус идёт за вкладкой: перетащивший её человек смотрит на неё, а не
        // на группу, из которой она уехала.
        activeGroup = target
        to.select(id: tab.id)
        return true
    }
}
