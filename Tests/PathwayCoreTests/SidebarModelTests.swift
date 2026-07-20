import Foundation
import Testing
@testable import PathwayCore

@MainActor
@Suite("SidebarModel — секции сайдбара")
struct SidebarModelTests {

    @Test("содержит четыре секции в порядке макета")
    func hasFourSectionsInOrder() {
        let model = SidebarModel()

        #expect(model.sections.map(\.title) == ["ИЗБРАННОЕ", "МЕСТА", "СЕТЬ", "МЕТКИ"])
    }

    @Test("избранное содержит закреплённые папки пользователя")
    func favoritesContainPinnedFolders() {
        let model = SidebarModel()

        let favorites = model.sections[0].items.map(\.name)

        #expect(favorites.contains("Рабочий стол"))
        #expect(favorites.contains("Документы"))
        #expect(favorites.contains("Загрузки"))
        #expect(favorites.contains("Изображения"))
    }

    @Test("места начинаются с «Этот Mac»")
    func placesStartWithThisMac() {
        let model = SidebarModel()

        let first = model.sections[1].items.first

        #expect(first?.name == "Этот Mac")
        #expect(first?.url.path == "/")
    }

    @Test("места содержат iCloud Drive, если папка существует")
    func placesIncludeICloudWhenPresent() {
        let model = SidebarModel()
        let icloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let hasICloudOnDisk = FileManager.default.fileExists(atPath: icloud.path)

        let names = model.sections[1].items.map(\.name)

        #expect(names.contains("iCloud Drive") == hasICloudOnDisk)
    }

    @Test("метки содержат стандартные цвета macOS")
    func tagsContainSystemColors() {
        let model = SidebarModel()

        let tags = model.sections[3].items.map(\.name)

        #expect(tags.contains("Красный"))
        #expect(tags.contains("Синий"))
        #expect(tags.count == 7)
    }

    @Test("сеть содержит пункт подключения к серверу")
    func networkHasConnectAction() {
        let model = SidebarModel()

        #expect(model.sections[2].items.map(\.name) == ["Подключиться к серверу…"])
    }
}

@MainActor
@Suite("SidebarModel — раскрытие дерева")
struct SidebarExpansionTests {

    @Test("по умолчанию раскрыт только «Этот Mac»")
    func thisMacExpandedByDefault() {
        let model = SidebarModel()

        #expect(model.isExpanded(URL(fileURLWithPath: "/")))
        #expect(!model.isExpanded(URL(fileURLWithPath: "/Users")))
    }

    @Test("переключает раскрытие узла")
    func togglesExpansion() {
        let model = SidebarModel()
        let url = URL(fileURLWithPath: "/Users")

        model.toggleExpansion(url)
        #expect(model.isExpanded(url))

        model.toggleExpansion(url)
        #expect(!model.isExpanded(url))
    }

    @Test("раскрывает всю ветку до текущей папки")
    func revealsPathToCurrentFolder() {
        let model = SidebarModel()

        model.reveal(URL(fileURLWithPath: "/Users/alex/Documents/Projects"))

        #expect(model.isExpanded(URL(fileURLWithPath: "/")))
        #expect(model.isExpanded(URL(fileURLWithPath: "/Users")))
        #expect(model.isExpanded(URL(fileURLWithPath: "/Users/alex")))
        #expect(model.isExpanded(URL(fileURLWithPath: "/Users/alex/Documents")))
        #expect(!model.isExpanded(URL(fileURLWithPath: "/Users/alex/Documents/Projects")),
                "саму целевую папку раскрывать не нужно")
    }

    @Test("хвостовой слэш не мешает определить раскрытие")
    func expansionIgnoresTrailingSlash() {
        let model = SidebarModel()

        model.toggleExpansion(URL(fileURLWithPath: "/Users/alex/"))

        #expect(model.isExpanded(URL(fileURLWithPath: "/Users/alex")))
    }
}
