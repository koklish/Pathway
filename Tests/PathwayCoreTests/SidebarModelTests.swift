import Foundation
import Testing
@testable import PathwayCore

@MainActor
@Suite("SidebarModel — секции сайдбара")
struct SidebarModelTests {

    // Здесь только статичные секции. «Сеть» собирает SidebarView из ServerBookmarks,
    // «Избранное» — из FavoritesStore: обе меняются во время работы.
    @Test("содержит статичные секции в порядке макета")
    func hasStaticSectionsInOrder() {
        let model = SidebarModel()

        #expect(model.sections.map(\.title) == ["МЕСТА", "МЕТКИ"])
    }

    @Test("места начинаются с «Этот Mac»")
    func placesStartWithThisMac() {
        let model = SidebarModel()

        let first = model.items(in: "МЕСТА").first

        #expect(first?.name == "Этот Mac")
        #expect(first?.url.path == "/")
    }

    @Test("места содержат iCloud Drive, если папка существует")
    func placesIncludeICloudWhenPresent() {
        let model = SidebarModel()
        let icloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let hasICloudOnDisk = FileManager.default.fileExists(atPath: icloud.path)

        let names = model.items(in: "МЕСТА").map(\.name)

        #expect(names.contains("iCloud Drive") == hasICloudOnDisk)
    }

    @Test("места не показывают сетевые тома — им место в секции «Сеть»")
    func placesExcludeNetworkVolumes() {
        let model = SidebarModel()
        let keys: [URLResourceKey] = [.volumeIsLocalKey]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) ?? []
        let networkVolumes = mounted.filter { url in
            (try? url.resourceValues(forKeys: Set(keys)))?.volumeIsLocal == false
        }

        let placePaths = Set(model.items(in: "МЕСТА").map(\.url.path))

        // На машине без сетевых томов проверять нечего — тест остаётся честным.
        for volume in networkVolumes {
            #expect(!placePaths.contains(volume.path), "сетевой том \(volume.path) не должен быть в «Местах»")
        }
    }

    @Test("места показывают локальные тома")
    func placesIncludeLocalVolumes() {
        let model = SidebarModel()
        let keys: [URLResourceKey] = [.volumeIsLocalKey]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) ?? []
        let localVolumes = mounted.filter { url in
            url.path != "/" && (try? url.resourceValues(forKeys: Set(keys)))?.volumeIsLocal == true
        }

        let placePaths = Set(model.items(in: "МЕСТА").map(\.url.path))

        for volume in localVolumes {
            #expect(placePaths.contains(volume.path), "локальный том \(volume.path) должен быть в «Местах»")
        }
    }

    @Test("метки содержат стандартные цвета macOS")
    func tagsContainSystemColors() {
        let model = SidebarModel()

        let tags = model.items(in: "МЕТКИ").map(\.name)

        #expect(tags.contains("Красный"))
        #expect(tags.contains("Синий"))
        #expect(tags.count == 7)
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

    /// Раскрытием дерева распоряжается только пользователь. Раньше навигация звала
    /// reveal, и свёрнутый «Этот Mac» разворачивался обратно при переходе на сетевой
    /// том или в iCloud Drive — оба лежат внутри корня.
    @Test("свёрнутый корень не разворачивается сам")
    func keepsCollapsedRootCollapsed() {
        let model = SidebarModel()
        let root = URL(fileURLWithPath: "/")
        #expect(model.isExpanded(root), "по умолчанию корень раскрыт")

        model.toggleExpansion(root)

        #expect(!model.isExpanded(root))
        // Единственный способ раскрыть узел обратно — снова позвать toggleExpansion.
        model.toggleExpansion(root)
        #expect(model.isExpanded(root))
    }

    /// Страховка от возврата прежнего поведения: раскрытие вложенного узла
    /// не должно тянуть за собой родителей.
    @Test("раскрытие узла не трогает соседние и родительские")
    func expansionDoesNotCascade() {
        let model = SidebarModel()
        let deep = URL(fileURLWithPath: "/Users/alex/Documents")

        model.toggleExpansion(deep)

        #expect(model.isExpanded(deep))
        #expect(!model.isExpanded(URL(fileURLWithPath: "/Users")))
        #expect(!model.isExpanded(URL(fileURLWithPath: "/Users/alex")))
    }

    @Test("хвостовой слэш не мешает определить раскрытие")
    func expansionIgnoresTrailingSlash() {
        let model = SidebarModel()

        model.toggleExpansion(URL(fileURLWithPath: "/Users/alex/"))

        #expect(model.isExpanded(URL(fileURLWithPath: "/Users/alex")))
    }
}
