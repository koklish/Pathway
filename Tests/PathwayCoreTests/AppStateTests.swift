import Foundation
import Testing
@testable import PathwayCore

@MainActor
@Suite("AppState — избранное и настройки")
struct AppStateTests {

    @Test("по умолчанию содержит стандартные папки пользователя")
    func hasDefaultFavorites() {
        let state = AppState()

        let names = state.favorites.map(\.name)
        #expect(names.contains("Рабочий стол"))
        #expect(names.contains("Документы"))
        #expect(names.contains("Загрузки"))
    }

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

    @Test("добавляет папку в избранное и не создаёт дубликатов")
    func addsFavoriteWithoutDuplicates() {
        let state = AppState()
        let folder = URL(fileURLWithPath: "/Users/alex/Projects")

        state.addFavorite(folder)
        state.addFavorite(folder)

        #expect(state.favorites.filter { $0.url == folder }.count == 1)
    }

    @Test("удаляет папку из избранного")
    func removesFavorite() {
        let state = AppState()
        let folder = URL(fileURLWithPath: "/Users/alex/Projects")
        state.addFavorite(folder)

        state.removeFavorite(folder)

        #expect(!state.favorites.contains { $0.url == folder })
    }
}
