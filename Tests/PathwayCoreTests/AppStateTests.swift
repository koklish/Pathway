import Foundation
import Testing
@testable import PathwayCore

@MainActor
@Suite("AppState — настройки")
struct AppStateTests {

    /// Своё хранилище вкладок: без него тесты открыли бы вкладки пользователя
    /// из UserDefaults.standard и сохранили бы туда свои.
    private func makeTabs(path: URL? = nil) -> TabsModel {
        let suite = "appstate.tabs." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return TabsModel(
            path: path ?? FileManager.default.homeDirectoryForCurrentUser,
            store: TabsStore(defaults: defaults)
        )
    }

    @Test("скрытые файлы по умолчанию не показываются")
    func hidesHiddenFilesByDefault() {
        #expect(!AppState(tabs: makeTabs()).showHiddenFiles)
    }

    @Test("панель — это активная вкладка")
    func browserIsActiveTab() {
        let state = AppState(tabs: makeTabs())

        state.tabs.open(URL(fileURLWithPath: "/tmp"), activate: true)

        #expect(state.browser === state.tabs.active.browser)
        #expect(state.browser.pane.path.path == "/tmp")
    }

    @Test("переключение вкладки меняет панель, с которой работают команды")
    func switchingTabChangesBrowser() {
        let state = AppState(tabs: makeTabs())
        state.tabs.open(URL(fileURLWithPath: "/tmp"), activate: true)

        state.tabs.select(index: 0)

        #expect(state.browser.pane.path != URL(fileURLWithPath: "/tmp"))
    }

    @Test("показ скрытых файлов доходит до вкладок, а не остаётся в настройке")
    func hiddenFilesReachTabs() {
        let state = AppState(tabs: makeTabs())
        state.tabs.open(URL(fileURLWithPath: "/tmp"), activate: false)

        state.showHiddenFiles = true

        #expect(state.tabs.tabs.allSatisfy { $0.browser.showHiddenFiles })
    }

    @Test("переключатель скрытых файлов меняет значение")
    func togglesHiddenFiles() {
        let state = AppState(tabs: makeTabs())

        state.showHiddenFiles.toggle()

        #expect(state.showHiddenFiles)
    }

    @Test("избранное доступно через общее состояние")
    func exposesFavorites() {
        let suite = "appstate.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let state = AppState(tabs: makeTabs(), favorites: FavoritesStore(defaults: defaults))

        #expect(!state.favorites.items.isEmpty)
    }

    @Test("онбординг доступен через общее состояние и по умолчанию не идёт")
    func exposesOnboarding() {
        let suite = "appstate.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let state = AppState(tabs: makeTabs(), onboarding: OnboardingModel(defaults: defaults))

        #expect(!state.onboarding.isActive)
    }
}
