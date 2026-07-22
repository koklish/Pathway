import Foundation
import Testing

@testable import PathwayCore

@Suite("Избранное")
@MainActor
struct FavoritesStoreTests {
    /// Каждому тесту — свой чистый UserDefaults, иначе они видят чужие записи.
    private func makeDefaults() -> UserDefaults {
        let suite = "favorites.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private let documents = URL(fileURLWithPath: "/Users/tester/Documents")
    private let projects = URL(fileURLWithPath: "/Users/tester/Projects")

    @Test("при первом запуске список заполняется стандартными папками")
    func seedsDefaultsOnFirstRun() {
        let store = FavoritesStore(defaults: makeDefaults())

        #expect(!store.items.isEmpty)
        // Домашние папки пользователя, а не чужие пути.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(store.items.allSatisfy { $0.url.path.hasPrefix(home) })
    }

    @Test("после очистки список не засевается заново")
    func doesNotReseedAfterUserClearsList() {
        let defaults = makeDefaults()
        let store = FavoritesStore(defaults: defaults)
        store.items.forEach { store.remove($0.id) }
        #expect(store.items.isEmpty)

        let reopened = FavoritesStore(defaults: defaults)

        #expect(reopened.items.isEmpty)
    }

    @Test("добавленная папка переживает перезапуск")
    func persistsAcrossInstances() {
        let defaults = makeDefaults()
        let store = FavoritesStore(defaults: defaults)
        store.add(projects)

        let reopened = FavoritesStore(defaults: defaults)

        #expect(reopened.contains(projects))
        #expect(reopened.items.last?.url.path == projects.path)
    }

    @Test("повторное добавление того же пути ничего не меняет")
    func addingDuplicateIsNoOp() {
        let store = FavoritesStore(defaults: makeDefaults())
        store.add(projects)
        let countAfterFirst = store.items.count

        store.add(projects)

        #expect(store.items.count == countAfterFirst)
    }

    @Test("хвостовой слэш не создаёт второй записи о той же папке")
    func trailingSlashIsSamePath() {
        let store = FavoritesStore(defaults: makeDefaults())
        store.add(projects)
        let countAfterFirst = store.items.count

        store.add(URL(fileURLWithPath: projects.path + "/"))

        #expect(store.items.count == countAfterFirst)
        #expect(store.contains(URL(fileURLWithPath: projects.path + "/")))
    }

    @Test("удаление убирает папку из списка")
    func removesItem() {
        let store = FavoritesStore(defaults: makeDefaults())
        store.add(projects)
        let added = store.items.last!

        store.remove(added.id)

        #expect(!store.contains(projects))
    }

    @Test("удаление по пути работает без знания идентификатора")
    func removesByURL() {
        let store = FavoritesStore(defaults: makeDefaults())
        store.add(projects)

        store.remove(url: projects)

        #expect(!store.contains(projects))
    }

    @Test("папку можно вставить в конкретное место списка")
    func insertsAtIndex() {
        let store = FavoritesStore(defaults: makeDefaults())

        store.add(projects, at: 0)

        #expect(store.items.first?.url.path == projects.path)
    }

    @Test("перемещение меняет порядок и переживает перезапуск")
    func reordersAndPersists() {
        let defaults = makeDefaults()
        let store = FavoritesStore(defaults: defaults)
        store.items.forEach { store.remove($0.id) }
        store.add(documents)
        store.add(projects)

        store.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        #expect(store.items.map(\.url.path) == [projects.path, documents.path])
        let reopened = FavoritesStore(defaults: defaults)
        #expect(reopened.items.map(\.url.path) == [projects.path, documents.path])
    }

    @Test("contains отвечает нет для папки вне списка")
    func containsIsFalseForUnknownPath() {
        let store = FavoritesStore(defaults: makeDefaults())

        #expect(!store.contains(URL(fileURLWithPath: "/nowhere/at/all")))
    }

    @Test("имя по умолчанию — название папки")
    func defaultNameIsFolderName() {
        let store = FavoritesStore(defaults: makeDefaults())

        store.add(projects)

        #expect(store.items.last?.name == "Projects")
    }
}
