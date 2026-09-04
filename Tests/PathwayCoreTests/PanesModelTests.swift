import Foundation
import Testing

@testable import PathwayCore

@Suite("Панели со своими вкладками")
@MainActor
struct PanesModelTests {
    /// Своё хранилище на каждый тест: общий UserDefaults протащил бы сессию из
    /// соседнего теста, и восстановление проверялось бы против чужих вкладок.
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "panes-\(UUID().uuidString)")!
    }

    private func makeModel(
        path: URL? = nil, defaults: UserDefaults? = nil
    ) -> PanesModel {
        PanesModel(path: path ?? home, defaults: defaults ?? makeDefaults())
    }

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private let tmp = URL(fileURLWithPath: "/tmp")
    private let usr = URL(fileURLWithPath: "/usr")

    // MARK: - Включение и выключение

    @Test("без сплита есть только левая группа")
    func startsWithLeftOnly() {
        let panes = makeModel()
        #expect(!panes.isSplit)
        #expect(panes.right == nil)
        #expect(panes.activeGroup == .left)
        #expect(panes.groups.count == 1)
    }

    @Test("сплит открывает правую группу на папке активной вкладки, а не на домашней")
    func splitOpensAtCurrentFolder() {
        let panes = makeModel(path: home)
        panes.left.active.browser.pane.navigate(to: tmp)

        panes.openSplit()

        #expect(panes.isSplit)
        #expect(panes.right?.active.browser.pane.path == PaneState.normalize(tmp))
    }

    @Test("включение сплита переводит фокус на новую панель")
    func splitFocusesRight() {
        let panes = makeModel()
        panes.openSplit()
        #expect(panes.activeGroup == .right)
        #expect(panes.active === panes.right)
    }

    @Test("выключение сплита возвращает фокус налево")
    func closingSplitFocusesLeft() {
        let panes = makeModel()
        panes.openSplit()
        panes.closeSplit()

        #expect(!panes.isSplit)
        #expect(panes.activeGroup == .left)
        #expect(panes.active === panes.left)
    }

    @Test("повторное включение сплита не создаёт третью группу")
    func openingSplitTwiceIsNoop() {
        let panes = makeModel()
        panes.openSplit()
        let right = panes.right
        panes.openSplit()
        #expect(panes.right === right)
    }

    // MARK: - Фокус

    @Test("⇥ переносит фокус на другую сторону и возвращает обратно")
    func focusOtherTogglesSides() {
        let panes = makeModel()
        panes.openSplit()

        panes.focusOther()
        #expect(panes.activeGroup == .left)

        panes.focusOther()
        #expect(panes.activeGroup == .right)
    }

    @Test("без сплита переключение фокуса ничего не делает, а не уводит в несуществующую панель")
    func focusOtherWithoutSplitIsNoop() {
        let panes = makeModel()
        panes.focusOther()
        #expect(panes.activeGroup == .left)
        #expect(panes.active === panes.left)
    }

    @Test("активная группа отдаёт свои вкладки, а не всегда левые")
    func activeFollowsFocus() {
        let panes = makeModel()
        panes.openSplit()
        #expect(panes.active === panes.right)

        panes.focus(.left)
        #expect(panes.active === panes.left)
    }

    // MARK: - Независимость групп

    @Test("вкладка, открытая в одной группе, не появляется в другой")
    func openingIsPerGroup() {
        let panes = makeModel()
        panes.openSplit()

        panes.right?.open(tmp)

        #expect(panes.right?.tabs.count == 2)
        #expect(panes.left.tabs.count == 1)
    }

    @Test("выделение и история у групп независимы")
    func selectionAndHistoryAreIndependent() {
        let panes = makeModel()
        panes.openSplit()

        panes.left.active.browser.pane.selection = [tmp]
        panes.left.active.browser.pane.navigate(to: usr)

        #expect(panes.right?.active.browser.pane.selection.isEmpty == true)
        #expect(panes.right?.active.browser.pane.canGoBack == false)
    }

    @Test("закрепление в правой группе не трогает левую")
    func pinningIsPerGroup() {
        let panes = makeModel()
        panes.openSplit()
        panes.right?.open(tmp)

        panes.right?.pin(id: panes.right!.active.id)

        #expect(panes.right?.tabs.contains { $0.isPinned } == true)
        #expect(panes.left.tabs.allSatisfy { !$0.isPinned })
    }

    // MARK: - Общие настройки

    @Test("показ скрытых файлов доходит до обеих групп, а не только до активной")
    func showHiddenReachesBothGroups() {
        let panes = makeModel()
        panes.openSplit()

        panes.showHiddenFiles = true

        #expect(panes.left.showHiddenFiles)
        #expect(panes.right?.showHiddenFiles == true)
    }

    @Test("сортировка доходит до обеих групп")
    func sortReachesBothGroups() {
        let panes = makeModel()
        panes.openSplit()

        panes.sort = SortSettings(key: "size", ascending: false)

        #expect(panes.left.sort.key == "size")
        #expect(panes.right?.sort.key == "size")
    }

    @Test("правая группа получает текущие настройки при открытии, а не умолчания")
    func newGroupInheritsSettings() {
        let panes = makeModel()
        panes.showHiddenFiles = true
        panes.sort = SortSettings(key: "size", ascending: false)

        panes.openSplit()

        #expect(panes.right?.showHiddenFiles == true)
        #expect(panes.right?.sort.key == "size")
    }

    // MARK: - Перенос вкладки между группами

    @Test("перенос перевозит ту же вкладку, а не открывает копию по пути")
    func moveCarriesSameTab() {
        let panes = makeModel()
        panes.openSplit()
        panes.left.open(tmp)
        let moved = panes.left.active
        let id = moved.id

        let ok = panes.moveTab(id: id, from: .left, to: .right)

        #expect(ok)
        #expect(panes.right?.tabs.contains { $0 === moved } == true)
        #expect(panes.left.tabs.contains { $0.id == id } == false)
    }

    @Test("перенос сохраняет историю навигации вкладки, а не начинает её заново")
    func moveKeepsHistory() {
        let panes = makeModel()
        panes.openSplit()
        panes.left.open(tmp)
        let tab = panes.left.active
        tab.browser.pane.navigate(to: usr)
        #expect(tab.browser.pane.canGoBack)

        panes.moveTab(id: tab.id, from: .left, to: .right)

        #expect(tab.browser.pane.canGoBack)
    }

    @Test("последнюю вкладку группа не отдаёт: группа без вкладок невозможна")
    func lastTabIsNotMoved() {
        let panes = makeModel()
        panes.openSplit()
        let id = panes.left.active.id

        let ok = panes.moveTab(id: id, from: .left, to: .right)

        #expect(!ok)
        #expect(panes.left.tabs.count == 1)
    }

    @Test("фокус идёт за перенесённой вкладкой")
    func focusFollowsMovedTab() {
        let panes = makeModel()
        panes.openSplit()
        panes.focus(.left)
        panes.left.open(tmp)
        let id = panes.left.active.id

        panes.moveTab(id: id, from: .left, to: .right)

        #expect(panes.activeGroup == .right)
        #expect(panes.right?.active.id == id)
    }

    @Test("перенос в ту же группу ничего не делает")
    func moveToSameGroupIsNoop() {
        let panes = makeModel()
        panes.openSplit()
        panes.left.open(tmp)

        let ok = panes.moveTab(id: panes.left.active.id, from: .left, to: .left)

        #expect(!ok)
        #expect(panes.left.tabs.count == 2)
    }

    @Test("перенос незакреплённой вкладки не ставит её между закреплёнными")
    func movedTabLandsAfterPinned() {
        let panes = makeModel()
        panes.openSplit()
        panes.right?.open(tmp)
        panes.right?.pin(id: panes.right!.active.id)
        panes.left.open(usr)
        let id = panes.left.active.id

        // Индексом 0 просим встать в самое начало — туда, где закреплённые.
        panes.moveTab(id: id, from: .left, to: .right, at: 0)

        let index = panes.right?.tabs.firstIndex { $0.id == id }
        #expect(index == 1)
        #expect(panes.right?.tabs.first?.isPinned == true)
    }

    // MARK: - Сессия

    @Test("состояние сплита переживает перезапуск")
    func splitSurvivesRestart() {
        let defaults = makeDefaults()
        let first = makeModel(defaults: defaults)
        first.openSplit()

        let second = makeModel(defaults: defaults)

        #expect(second.isSplit)
    }

    @Test("выключенный сплит не восстанавливается")
    func closedSplitStaysClosed() {
        let defaults = makeDefaults()
        let first = makeModel(defaults: defaults)
        first.openSplit()
        first.closeSplit()

        let second = makeModel(defaults: defaults)

        #expect(!second.isSplit)
    }

    @Test("вкладки правой группы переживают перезапуск отдельно от левых")
    func rightGroupTabsSurviveRestart() {
        let defaults = makeDefaults()
        let first = makeModel(defaults: defaults)
        first.openSplit()
        first.right?.open(tmp)
        first.right?.open(usr)

        let second = makeModel(defaults: defaults)

        #expect(second.right?.tabs.count == 3)
        #expect(second.left.tabs.count == 1)
    }

    @Test("выключение сплита переносит вкладки правой группы в левую, а не закрывает их")
    func closingSplitMergesTabsIntoLeft() {
        let panes = makeModel()
        panes.openSplit()
        panes.right?.open(tmp)
        panes.right?.open(usr)
        let leftActive = panes.left.active

        panes.closeSplit()

        #expect(panes.left.tabs.count == 4)
        #expect(panes.right == nil)
        // Активной остаётся вкладка левой группы, а не приехавшая: консолидация
        // не должна перекидывать человека на другую папку.
        #expect(panes.left.active === leftActive)
    }

    @Test("перенесённые выключением вкладки сохраняют модель — историю навигации и прочитанный список")
    func closingSplitKeepsTabModels() {
        let panes = makeModel()
        panes.openSplit()
        panes.right?.open(tmp)
        let tab = panes.right!.active
        tab.browser.pane.navigate(to: usr)

        panes.closeSplit()

        // Та же самая вкладка, а не открытая заново по пути: иначе история
        // навигации и уже прочитанный список сетевой папки потерялись бы.
        #expect(panes.left.tabs.contains { $0 === tab })
        #expect(tab.browser.pane.canGoBack)
    }

    @Test("повторное включение сплита не воскрешает уехавшие влево вкладки")
    func reopenedSplitDoesNotDuplicateMergedTabs() {
        let defaults = makeDefaults()
        let first = makeModel(defaults: defaults)
        first.openSplit()
        first.right?.open(tmp)
        first.closeSplit()

        let second = makeModel(defaults: defaults)
        second.openSplit()

        // Сессия правой группы стёрта при выключении: её вкладки уехали в
        // левую, и воскресни они здесь — набор задвоился бы.
        #expect(second.right?.tabs.count == 1)
        #expect(second.left.tabs.count == 3)
    }

    @Test("группы пишут сессию по разным ключам, а не затирают друг друга")
    func groupsUseSeparateKeys() {
        let defaults = makeDefaults()
        let panes = makeModel(defaults: defaults)
        panes.openSplit()
        panes.left.open(tmp)
        panes.right?.open(usr)

        #expect(defaults.array(forKey: "tabs.items") != nil)
        #expect(defaults.array(forKey: "tabs.items.right") != nil)
    }

    @Test("левая группа пишет в ключи без суффикса — сессия, накопленная до сплита, не теряется")
    func leftKeepsLegacyKeys() {
        let defaults = makeDefaults()
        // Сессия, записанная версией без сплита.
        defaults.set([["path": tmp.path, "pinned": false]], forKey: "tabs.items")
        defaults.set(0, forKey: "tabs.activeIndex")

        let panes = makeModel(defaults: defaults)

        #expect(panes.left.tabs.count == 1)
        #expect(panes.left.active.browser.pane.path == PaneState.normalize(tmp))
    }

    // MARK: - Команды

    /// Состояние с панелями на изолированном хранилище: команды ходят через
    /// AppState, а тот собирает PanesModel сам.
    private func makeState(defaults: UserDefaults? = nil) -> AppState {
        let defaults = defaults ?? makeDefaults()
        return AppState(
            panes: PanesModel(path: home, defaults: defaults),
            favorites: FavoritesStore(defaults: defaults)
        )
    }

    private func run(_ id: CommandID, in state: AppState) {
        CommandRegistry[id].run(state)
    }

    private func isEnabled(_ id: CommandID, in state: AppState) -> Bool {
        CommandRegistry[id].isEnabled(state)
    }

    @Test("«Разделить окно» открывает вторую панель, а повторный вызов её убирает")
    func toggleSplitCommandOpensAndCloses() {
        let state = makeState()

        run(.toggleSplit, in: state)
        #expect(state.panes.isSplit)

        run(.toggleSplit, in: state)
        #expect(!state.panes.isSplit)
    }

    @Test("переход в другую панель гаснет без сплита")
    func focusOtherIsDisabledWithoutSplit() {
        let state = makeState()
        #expect(!isEnabled(.focusOtherPane, in: state))

        run(.toggleSplit, in: state)
        #expect(isEnabled(.focusOtherPane, in: state))
    }

    @Test("команды адресованы активной панели, а не всегда левой")
    func commandsTargetActivePane() {
        let state = makeState()
        run(.toggleSplit, in: state)
        // Сплит перевёл фокус вправо — новая вкладка обязана открыться там.
        let leftBefore = state.panes.left.tabs.count

        run(.newTab, in: state)

        #expect(state.panes.right?.tabs.count == 2)
        #expect(state.panes.left.tabs.count == leftBefore)
    }

    @Test("browser отдаёт папку активной панели, а не левой")
    func browserFollowsActivePane() {
        let state = makeState()
        run(.toggleSplit, in: state)
        state.panes.right?.active.browser.pane.navigate(to: tmp)

        #expect(state.browser.pane.path == PaneState.normalize(tmp))

        state.panes.focus(.left)
        #expect(state.browser.pane.path != PaneState.normalize(tmp))
    }

    @Test("старую сессию читает только левая группа, а не обе одинаково")
    func legacySessionGoesToLeftOnly() {
        let defaults = makeDefaults()
        defaults.set([tmp.path, usr.path], forKey: "tabs.paths")
        defaults.set(0, forKey: "tabs.activeIndex")
        defaults.set(true, forKey: "panes.isSplit")

        let panes = makeModel(defaults: defaults)

        #expect(panes.left.tabs.count == 2)
        // Правая начинает с одной вкладки на переданной папке, а не с копии
        // тех же двух: иначе после обновления набор задвоился бы.
        #expect(panes.right?.tabs.count == 1)
    }
}
