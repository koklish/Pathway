import Foundation
import Testing
@testable import PathwayCore

@MainActor
@Suite("AppState — настройки")
struct AppStateTests {

    @Test("скрытые файлы по умолчанию не показываются")
    func hidesHiddenFilesByDefault() {
        #expect(!AppState().showHiddenFiles)
    }

    @Test("переключатель скрытых файлов меняет значение")
    func togglesHiddenFiles() {
        let state = AppState()

        state.showHiddenFiles.toggle()

        #expect(state.showHiddenFiles)
    }

    @Test("избранное доступно через общее состояние")
    func exposesFavorites() {
        let suite = "appstate.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let state = AppState(favorites: FavoritesStore(defaults: defaults))

        #expect(!state.favorites.items.isEmpty)
    }
}
