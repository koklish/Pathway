import Foundation
import Testing

@testable import PathwayCore

@Suite("Вкладки")
@MainActor
struct TabsModelTests {
    /// Каждому тесту — свой чистый UserDefaults, иначе они видят чужие записи.
    private func makeDefaults() -> UserDefaults {
        let suite = "tabs.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Модель на существующих папках: пути проверяются на существование при
    /// восстановлении, поэтому выдуманные каталоги для этого не годятся.
    private func makeModel(
        path: URL? = nil, defaults: UserDefaults? = nil
    ) -> TabsModel {
        TabsModel(
            path: path ?? home,
            store: TabsStore(defaults: defaults ?? makeDefaults())
        )
    }

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private let tmp = URL(fileURLWithPath: "/tmp")
    private let usr = URL(fileURLWithPath: "/usr")
    private let library = URL(fileURLWithPath: "/Library")

    /// Незакреплённые записи сессии — обычный случай для тестов восстановления.
    private func records(_ paths: URL...) -> [TabRecord] {
        paths.map { TabRecord(path: $0) }
    }

    /// Пишет сессию в формате версий до 1.2.8 — плоским массивом путей, без
    /// признака закрепления. Только для проверки чтения старых сессий:
    /// приложение так больше не сохраняет.
    private func saveLegacy(_ paths: [URL], activeIndex: Int, to defaults: UserDefaults) {
        defaults.set(paths.map(\.path), forKey: "tabs.paths")
        defaults.set(activeIndex, forKey: "tabs.activeIndex")
    }

    // MARK: - Открытие

    @Test("начинает с одной вкладки на заданной папке")
    func startsWithSingleTab() {
        let model = makeModel()

        #expect(model.tabs.count == 1)
        #expect(model.active.browser.pane.path == home)
    }

    @Test("открывает вкладку и делает её активной")
    func opensAndActivates() {
        let model = makeModel()

        model.open(tmp, activate: true)

        #expect(model.tabs.count == 2)
        #expect(model.active.browser.pane.path.path == "/tmp")
    }

    @Test("фоновая вкладка не меняет активную")
    func backgroundTabKeepsActive() {
        let model = makeModel()
        let first = model.active.id

        model.open(tmp, activate: false)

        #expect(model.tabs.count == 2)
        #expect(model.active.id == first)
    }

    @Test("новая вкладка встаёт справа от активной, а не в конец списка")
    func insertsAfterActive() {
        let model = makeModel()
        model.open(tmp, activate: false)
        model.open(usr, activate: false)
        // Активна по-прежнему первая; открытая из неё вкладка должна встать второй.
        model.open(library, activate: false)

        #expect(model.tabs[1].browser.pane.path.path == "/Library")
    }

    // MARK: - Закрытие

    @Test("закрытие активной вкладки переводит фокус на правую соседку")
    func closingActivePicksRightNeighbour() {
        let model = makeModel()
        model.open(tmp, activate: true)
        model.open(usr, activate: false)
        // Порядок: home, /tmp (активна), /usr.

        model.closeActive()

        #expect(model.tabs.count == 2)
        #expect(model.active.browser.pane.path.path == "/usr")
    }

    @Test("закрытие последней в ряду вкладки переводит фокус на левую соседку")
    func closingLastPicksLeftNeighbour() {
        let model = makeModel()
        model.open(tmp, activate: true)

        model.closeActive()

        #expect(model.tabs.count == 1)
        #expect(model.active.browser.pane.path == home)
    }

    @Test("закрытие единственной вкладки ничего не делает")
    func closingOnlyTabDoesNothing() {
        let model = makeModel()

        model.closeActive()

        #expect(model.tabs.count == 1)
        #expect(model.canCloseActive == false)
    }

    @Test("закрытие неактивной вкладки сохраняет активной ту же вкладку, а не индекс")
    func closingInactiveKeepsSameTab() {
        let model = makeModel()
        model.open(tmp, activate: false)
        model.open(usr, activate: true)
        let active = model.active.id
        // Порядок: home, /usr (активна), /tmp — закрываем первую, слева от активной.

        model.close(id: model.tabs[0].id)

        #expect(model.active.id == active)
        #expect(model.active.browser.pane.path.path == "/usr")
    }

    @Test("«Закрыть другие» оставляет одну вкладку и делает её активной")
    func closeOthersLeavesOne() {
        let model = makeModel()
        model.open(tmp, activate: false)
        model.open(usr, activate: false)
        let kept = model.tabs[1].id

        model.closeOthers(id: kept)

        #expect(model.tabs.count == 1)
        #expect(model.active.id == kept)
    }

    @Test("«Закрыть справа» не трогает вкладки слева от указанной")
    func closeToTheRightKeepsLeft() {
        let model = makeModel()
        model.open(tmp, activate: false)
        model.open(usr, activate: false)
        model.open(library, activate: false)
        let pivot = model.tabs[1].id

        model.closeToTheRight(of: pivot)

        #expect(model.tabs.count == 2)
        #expect(model.tabs[1].id == pivot)
    }

    @Test("«Закрыть другие» загружает оставленную вкладку, если она была фоновой")
    func closeOthersLoadsKeptTab() async {
        let model = makeModel()
        model.open(tmp, activate: false)
        let kept = model.tabs[1]
        // Фоновая вкладка папку ещё не читала.
        #expect(kept.browser.items.isEmpty)

        model.closeOthers(id: kept.id)
        await model.active.browser.waitForLoad()

        #expect(!model.active.browser.items.isEmpty)
    }

    @Test("«Закрыть справа» загружает вкладку, ставшую активной")
    func closeToTheRightLoadsNewActive() async {
        let model = makeModel(path: tmp)
        model.open(usr, activate: true)
        // Активна вторая; закрываем всё справа от первой — активной станет она.
        model.closeToTheRight(of: model.tabs[0].id)
        await model.active.browser.waitForLoad()

        #expect(!model.active.browser.items.isEmpty)
    }

    @Test("закрытие вкладки отменяет её загрузку, а не ждёт её окончания")
    func closingCancelsLoad() async {
        let model = makeModel()
        model.open(tmp, activate: false)
        let closing = model.tabs[1]
        closing.browser.reloadAsync()

        model.close(id: closing.id)

        // Загрузка снята: ожидание завершается сразу, а не читает каталог до конца.
        await closing.browser.waitForLoad()
        #expect(closing.browser.isLoading == false)
    }

    // MARK: - Порядок и переключение

    @Test("перестановка сохраняет активной ту же вкладку, а не позицию")
    func moveKeepsActiveTab() {
        let model = makeModel()
        model.open(tmp, activate: true)
        let active = model.active.id

        model.move(from: 1, to: 0)

        #expect(model.active.id == active)
        #expect(model.tabs[0].id == active)
    }

    @Test("переход вперёд с последней вкладки возвращает к первой")
    func nextWrapsAround() {
        let model = makeModel()
        model.open(tmp, activate: true)
        let first = model.tabs[0].id

        model.selectNext()

        #expect(model.active.id == first)
    }

    @Test("переход назад с первой вкладки уводит к последней")
    func previousWrapsAround() {
        let model = makeModel()
        model.open(tmp, activate: false)
        let last = model.tabs[1].id

        model.selectPrevious()

        #expect(model.active.id == last)
    }

    @Test("переключение на ещё не читанную вкладку загружает её папку")
    func selectingLoadsUnreadTab() async {
        let model = makeModel()
        model.open(tmp, activate: false)
        // Фоновая вкладка папку ещё не читала: её список пуст.
        #expect(model.tabs[1].browser.items.isEmpty)

        model.select(index: 1)
        await model.active.browser.waitForLoad()

        #expect(!model.active.browser.items.isEmpty)
    }

    @Test("возврат на прочитанную вкладку отдаёт список сразу, не перечитывая папку")
    func returningKeepsLoadedItems() async {
        let model = makeModel(path: tmp)
        model.loadActive()
        await model.active.browser.waitForLoad()
        model.open(usr, activate: true)
        await model.active.browser.waitForLoad()
        let loaded = model.tabs[0].browser.items.count

        model.select(index: 0)

        // Список на месте сразу, без ожидания загрузки: в этом и смысл
        // вкладок — возврат должен быть мгновенным.
        #expect(model.tabs[0].browser.items.count == loaded)
        #expect(loaded > 0)
    }

    @Test("пустая папка считается прочитанной, а не читается на каждое переключение")
    func emptyFolderIsNotReloadedEveryTime() async throws {
        try await withTempDirAsync { dir in
            let model = makeModel(path: dir)
            model.loadActive()
            await model.active.browser.waitForLoad()
            model.open(tmp, activate: true)
            await model.active.browser.waitForLoad()

            model.select(index: 0)

            // Папка пуста, но помечена прочитанной — повторного обхода не будет.
            // Проверяем флаг, а не isLoading: тот успевает сброситься, и
            // лишнее чтение прошло бы мимо теста.
            #expect(model.tabs[0].browser.items.isEmpty)
            #expect(model.tabs[0].hasLoaded)
        }
    }

    // MARK: - Независимость вкладок

    @Test("выделение в одной вкладке не видно в другой")
    func selectionIsPerTab() {
        let model = makeModel()
        model.open(tmp, activate: false)
        let file = home.appendingPathComponent("файл.txt")

        model.tabs[0].browser.pane.selection = [file]

        #expect(model.tabs[1].browser.pane.selection.isEmpty)
    }

    @Test("история навигации у вкладок независима")
    func historyIsPerTab() {
        let model = makeModel()
        model.open(tmp, activate: false)

        model.tabs[0].browser.pane.navigate(to: usr)

        #expect(model.tabs[0].browser.pane.canGoBack)
        #expect(!model.tabs[1].browser.pane.canGoBack)
    }

    @Test("новая вкладка получает текущее значение показа скрытых файлов")
    func newTabInheritsShowHidden() {
        let model = makeModel()
        model.showHiddenFiles = true

        model.open(tmp, activate: true)

        #expect(model.active.browser.showHiddenFiles)
    }

    @Test("переключение показа скрытых файлов доходит до всех вкладок, а не только активной")
    func showHiddenReachesEveryTab() {
        let model = makeModel()
        model.open(tmp, activate: false)

        model.showHiddenFiles = true

        #expect(model.tabs.allSatisfy { $0.browser.showHiddenFiles })
    }

    // MARK: - Название вкладки

    @Test("названием служит имя папки, а для корня — «Этот Мас»")
    func titleUsesFolderName() {
        let model = makeModel(path: URL(fileURLWithPath: "/"))
        model.open(tmp, activate: false)

        #expect(model.tabs[0].title == "Этот Мас")
        #expect(model.tabs[1].title == "tmp")
    }

    // MARK: - Сохранение сессии

    @Test("состав вкладок и активная переживают перезапуск")
    func restoresTabsAndActive() {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        model.open(tmp, activate: false)
        model.open(usr, activate: true)

        let restored = makeModel(defaults: defaults)

        #expect(restored.tabs.count == 3)
        #expect(restored.active.browser.pane.path.path == "/usr")
    }

    @Test("сохраняется текущая папка вкладки, а не та, с которой её открыли")
    func savesCurrentFolder() async {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        model.active.browser.navigate(to: tmp)

        let restored = makeModel(defaults: defaults)

        #expect(restored.active.browser.pane.path.path == "/tmp")
    }

    @Test("несуществующие пути при восстановлении отбрасываются")
    func dropsMissingPaths() {
        let defaults = makeDefaults()
        let store = TabsStore(defaults: defaults)
        store.save(items: records(tmp, URL(fileURLWithPath: "/такой/папки/нет")), activeIndex: 0)

        let restored = makeModel(defaults: defaults)

        #expect(restored.tabs.count == 1)
        #expect(restored.active.browser.pane.path.path == "/tmp")
    }

    @Test("если не уцелел ни один путь, открывается домашняя папка")
    func fallsBackToHome() {
        let defaults = makeDefaults()
        let store = TabsStore(defaults: defaults)
        store.save(items: records(URL(fileURLWithPath: "/нет/такой")), activeIndex: 0)

        let restored = makeModel(defaults: defaults)

        #expect(restored.tabs.count == 1)
        #expect(restored.active.browser.pane.path == home)
    }

    @Test("сохранённый индекс за границами списка приводится к валидному")
    func clampsRestoredIndex() {
        let defaults = makeDefaults()
        let store = TabsStore(defaults: defaults)
        // Индекс указывает на вкладку, которая не уцелела.
        store.save(items: records(tmp, usr, URL(fileURLWithPath: "/нет")), activeIndex: 2)

        let restored = makeModel(defaults: defaults)

        #expect(restored.tabs.count == 2)
        #expect(restored.active.browser.pane.path.path == "/usr")
    }

    @Test("файл вместо папки при восстановлении отбрасывается")
    func dropsNonDirectories() {
        let defaults = makeDefaults()
        let store = TabsStore(defaults: defaults)
        // /usr/bin/env существует, но это файл — вкладкой он быть не может.
        store.save(items: records(tmp, URL(fileURLWithPath: "/usr/bin/env")), activeIndex: 0)

        let restored = makeModel(defaults: defaults)

        #expect(restored.tabs.count == 1)
    }

    // MARK: - Хранение сессии

    @Test("закрепление переживает перезапуск, а не только пути")
    func pinnedSurvivesRestart() {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        model.open(tmp)
        model.open(usr)
        model.pin(id: model.tabs[2].id)

        let restored = makeModel(defaults: defaults)

        #expect(restored.tabs[0].isPinned)
        #expect(restored.tabs[0].browser.pane.path.path == "/usr")
    }

    @Test("сессия старого формата читается, все вкладки незакреплённые")
    func readsLegacySession() {
        let defaults = makeDefaults()
        // Формат версий до 1.2.8: массив путей без признака закрепления.
        // Сессия коллеги, обновившегося с прошлой версии, обязана открыться
        // целиком — иначе обновление теряет все вкладки разом.
        saveLegacy([tmp, usr], activeIndex: 1, to: defaults)

        let restored = makeModel(defaults: defaults)

        #expect(restored.tabs.count == 2)
        #expect(restored.tabs.allSatisfy { !$0.isPinned })
        #expect(restored.active.browser.pane.path.path == "/usr")
    }

    @Test("сохранение в новом формате стирает старый ключ, а не оставляет оба")
    func savingRemovesLegacyKey() {
        let defaults = makeDefaults()
        saveLegacy([tmp], activeIndex: 0, to: defaults)

        let model = makeModel(defaults: defaults)
        model.open(usr)

        // Оставленный ключ пережил бы откат на прошлую версию и подсунул бы ей
        // вкладки, которых у пользователя уже нет.
        #expect(defaults.stringArray(forKey: "tabs.paths") == nil)
    }

    @Test("мёртвый путь закреплённой вкладки отбрасывается так же, как обычной")
    func dropsMissingPinnedPath() {
        let defaults = makeDefaults()
        let store = TabsStore(defaults: defaults)
        store.save(
            items: [
                TabRecord(path: URL(fileURLWithPath: "/нет/такой"), isPinned: true),
                TabRecord(path: tmp),
            ],
            activeIndex: 1
        )

        let restored = makeModel(defaults: defaults)

        #expect(restored.tabs.count == 1)
        #expect(restored.active.browser.pane.path.path == "/tmp")
    }

    // MARK: - Закрепление

    @Test("закреплённая вкладка встаёт в начало списка, а не остаётся на месте")
    func pinMovesTabToFront() {
        let model = makeModel()
        model.open(tmp)
        model.open(usr)
        let pinned = model.active.id

        model.pin(id: pinned)

        #expect(model.tabs[0].id == pinned)
        #expect(model.tabs[0].isPinned)
    }

    @Test("закрепление не меняет активную вкладку, хотя двигает её по списку")
    func pinKeepsActiveTab() {
        let model = makeModel()
        model.open(tmp)
        model.open(usr)
        let active = model.active.id

        model.pin(id: model.tabs[1].id)

        #expect(model.active.id == active)
    }

    @Test("открепление возвращает вкладку в начало обычной группы, а не в конец списка")
    func unpinMovesToStartOfRegulars() {
        let model = makeModel()
        model.open(tmp)
        model.open(usr)
        model.pin(id: model.tabs[0].id)
        model.pin(id: model.tabs[1].id)
        let unpinned = model.tabs[1].id

        model.unpin(id: unpinned)

        // После двух закреплённых: индекс 1 — начало обычной группы.
        #expect(model.tabs[1].id == unpinned)
        #expect(!model.tabs[1].isPinned)
    }

    @Test("повторное закрепление ничего не меняет")
    func pinIsIdempotent() {
        let model = makeModel()
        model.open(tmp)
        model.pin(id: model.active.id)
        let order = model.tabs.map(\.id)

        model.pin(id: model.tabs[0].id)

        #expect(model.tabs.map(\.id) == order)
    }

    @Test("закреплённая вкладка не закрывается")
    func pinnedTabDoesNotClose() {
        let model = makeModel()
        model.open(tmp)
        let pinned = model.active.id
        model.pin(id: pinned)

        model.close(id: pinned)

        #expect(model.tabs.contains { $0.id == pinned })
        #expect(!model.canClose(id: pinned))
    }

    @Test("⌘W на закреплённой активной вкладке недоступна")
    func canCloseActiveIsFalseWhenPinned() {
        let model = makeModel()
        model.open(tmp)
        model.pin(id: model.active.id)

        #expect(!model.canCloseActive)
    }

    @Test("«Закрыть другие» оставляет закреплённые, а не только указанную")
    func closeOthersKeepsPinned() {
        let model = makeModel()
        model.open(tmp)
        model.open(usr)
        model.open(library)
        model.pin(id: model.tabs[1].id)
        let kept = model.tabs[3].id
        let pinned = model.tabs[0].id

        model.closeOthers(id: kept)

        #expect(model.tabs.count == 2)
        #expect(model.tabs.contains { $0.id == pinned })
        #expect(model.active.id == kept)
    }

    @Test("«Закрыть вкладки справа» на закреплённой оставляет закреплённые справа")
    func closeToTheRightKeepsPinned() {
        let model = makeModel()
        model.open(tmp)
        model.open(usr)
        // Закреплённая справа от обычной невозможна — группы этого не
        // допускают. Единственный случай, где справа от вкладки есть
        // закреплённые, — когда сама вкладка тоже закреплена, и именно ради
        // него в closeToTheRight стоит исключение.
        model.pin(id: model.tabs[1].id)
        model.pin(id: model.tabs[2].id)
        let anchor = model.tabs[0].id
        let neighbour = model.tabs[1].id
        let doomed = model.tabs[2].id

        model.closeToTheRight(of: anchor)

        #expect(model.tabs.contains { $0.id == neighbour }, "закреплённая справа должна уцелеть")
        #expect(!model.tabs.contains { $0.id == doomed }, "обычная справа должна закрыться")
        #expect(model.tabs.count == 2)
    }

    @Test("новая вкладка из закреплённой встаёт после всех закреплённых")
    func openFromPinnedGoesAfterPinnedGroup() {
        let model = makeModel()
        model.open(tmp)
        model.pin(id: model.tabs[0].id)
        model.pin(id: model.tabs[1].id)
        model.select(index: 0)

        model.open(library)

        // Обе закреплённые остались слева, новая встала сразу за ними.
        #expect(model.tabs[0].isPinned)
        #expect(model.tabs[1].isPinned)
        #expect(model.tabs[2].browser.pane.path == library)
    }

    @Test("перетаскивание не уводит обычную вкладку левее закреплённых")
    func moveKeepsRegularOutOfPinnedGroup() {
        let model = makeModel()
        model.open(tmp)
        model.open(usr)
        model.pin(id: model.tabs[0].id)
        let regular = model.tabs[2].id

        model.move(from: 2, to: 0)

        #expect(model.tabs[0].isPinned)
        #expect(model.tabs[1].id == regular)
    }

    @Test("перетаскивание не уводит закреплённую вкладку правее обычных")
    func moveKeepsPinnedOutOfRegulars() {
        let model = makeModel()
        model.open(tmp)
        model.open(usr)
        model.pin(id: model.tabs[0].id)
        let pinned = model.tabs[0].id

        model.move(from: 0, to: 2)

        #expect(model.tabs[0].id == pinned)
    }

    // MARK: - Слежение за папкой

    /// Модель с подменными наблюдателями: настоящий FSEvents во вкладках
    /// потребовал бы ждать событий от ядра.
    private func makeWatchedModel() -> (TabsModel, WatcherFactory) {
        let factory = WatcherFactory()
        let model = TabsModel(
            path: home,
            store: TabsStore(defaults: makeDefaults()),
            makeWatcher: { factory.make() }
        )
        return (model, factory)
    }

    /// Раздаёт наблюдателей вкладкам и помнит всех выданных.
    @MainActor
    final class WatcherFactory {
        private(set) var watchers: [FakeDirectoryWatcher] = []

        func make() -> FakeDirectoryWatcher {
            let watcher = FakeDirectoryWatcher()
            watchers.append(watcher)
            return watcher
        }

        /// Наблюдатели, следящие за папкой прямо сейчас.
        var active: [FakeDirectoryWatcher] { watchers.filter(\.isWatching) }
    }

    @Test("слежение включено только у активной вкладки, а не у всех сразу")
    func onlyActiveTabIsWatched() async throws {
        let (model, factory) = makeWatchedModel()
        model.loadActive()
        await model.active.browser.waitForLoad()

        model.open(tmp)
        await model.active.browser.waitForLoad()

        #expect(factory.active.count == 1)
        #expect(factory.active.first?.watched?.path == "/tmp")
    }

    @Test("переключение вкладок переносит слежение на новую активную")
    func switchingTabsMovesWatch() async throws {
        let (model, factory) = makeWatchedModel()
        model.loadActive()
        await model.active.browser.waitForLoad()
        model.open(tmp)
        await model.active.browser.waitForLoad()

        model.select(index: 0)
        await model.active.browser.waitForLoad()

        #expect(factory.active.count == 1)
        #expect(factory.active.first?.watched?.path == home.path)
    }

    @Test("возврат на прочитанную вкладку обновляет её, не сбрасывая hasLoaded")
    func returningToTabRefreshesIt() async throws {
        let (model, _) = makeWatchedModel()
        model.loadActive()
        await model.active.browser.waitForLoad()
        model.open(tmp)
        await model.active.browser.waitForLoad()

        model.select(index: 0)
        await model.active.browser.waitForRefresh()

        #expect(model.active.hasLoaded)
        // Список не должен мигнуть пустым: показ мгновенный, обновление поверх.
        #expect(!model.active.browser.items.isEmpty)
    }

    @Test("закрытие вкладки останавливает её слежение")
    func closingTabStopsWatching() async throws {
        let (model, factory) = makeWatchedModel()
        model.loadActive()
        await model.active.browser.waitForLoad()
        model.open(tmp)
        await model.active.browser.waitForLoad()
        let closed = try #require(factory.active.first)

        model.closeActive()

        #expect(closed.stopCount >= 1)
    }
}
