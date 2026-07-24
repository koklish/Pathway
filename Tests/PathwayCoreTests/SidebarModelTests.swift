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

    @Test("раскрывает ветку до текущей папки внутри её корня")
    func revealsPathWithinItsRoot() {
        let model = SidebarModel()
        let root = URL(fileURLWithPath: "/")
        // Свернём корень, чтобы его раскрытие было заслугой reveal, а не умолчания.
        model.toggleExpansion(root)

        model.reveal(URL(fileURLWithPath: "/Users/alex/Documents/Projects"), roots: [root])

        #expect(model.isExpanded(root))
        #expect(model.isExpanded(URL(fileURLWithPath: "/Users")))
        #expect(model.isExpanded(URL(fileURLWithPath: "/Users/alex")))
        #expect(model.isExpanded(URL(fileURLWithPath: "/Users/alex/Documents")))
        #expect(!model.isExpanded(URL(fileURLWithPath: "/Users/alex/Documents/Projects")),
                "саму целевую папку раскрывать не нужно")
    }

    /// Главный случай: сетевой том лежит в /Volumes, то есть внутри корня, но
    /// показан отдельным пунктом. Раскрывать ради него «Этот Mac» незачем —
    /// пользователь его свернул намеренно, а искомая папка видна в своей секции.
    @Test("папка на сетевом томе не разворачивает «Этот Mac»")
    func revealOnVolumeLeavesMacAlone() {
        let model = SidebarModel()
        let root = URL(fileURLWithPath: "/")
        let volume = URL(fileURLWithPath: "/Volumes/Спецификации")
        model.toggleExpansion(root)
        #expect(!model.isExpanded(root))

        model.reveal(volume.appendingPathComponent("Проекты/2026"), roots: [root, volume])

        #expect(model.isExpanded(volume), "ветка самого тома раскрыта")
        #expect(model.isExpanded(volume.appendingPathComponent("Проекты")))
        #expect(!model.isExpanded(root), "«Этот Mac» остался свёрнутым")
        #expect(!model.isExpanded(URL(fileURLWithPath: "/Volumes")))
    }

    /// iCloud Drive — тот же случай: он внутри домашней папки, но свой корень.
    @Test("папка в iCloud Drive не разворачивает «Этот Mac»")
    func revealInICloudLeavesMacAlone() {
        let model = SidebarModel()
        let root = URL(fileURLWithPath: "/")
        let icloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        model.toggleExpansion(root)

        model.reveal(icloud.appendingPathComponent("Документы"), roots: [root, icloud])

        #expect(model.isExpanded(icloud))
        #expect(!model.isExpanded(root))
        #expect(!model.isExpanded(icloud.deletingLastPathComponent()),
                "промежуточные папки чужого корня не раскрываются")
    }

    /// Из нескольких подходящих корней берётся самый глубокий: и «/», и том
    /// содержат путь, но ветка должна расти от тома.
    @Test("выбирается ближайший корень, а не первый подходящий")
    func picksDeepestRoot() {
        let model = SidebarModel()
        let root = URL(fileURLWithPath: "/")
        let volume = URL(fileURLWithPath: "/Volumes/Данные")
        // Корень раскрыт по умолчанию, поэтому сворачиваем его: иначе проверка
        // «reveal его не трогал» прошла бы сама собой.
        model.toggleExpansion(root)

        model.reveal(volume.appendingPathComponent("Отчёты"), roots: [root, volume])

        #expect(model.isExpanded(volume))
        #expect(!model.isExpanded(root))
        #expect(!model.isExpanded(URL(fileURLWithPath: "/Volumes")))
    }

    /// Точки монтирования приходят снаружи: секция «Сеть» строится во вью,
    /// а не в SidebarModel, и о подключённых серверах модель сама не знает.
    @Test("корнями служат пункты «Мест» вместе с сетевыми томами")
    func treeRootsIncludeNetworkMounts() {
        let model = SidebarModel()
        let mount = URL(fileURLWithPath: "/Volumes/Спецификации")

        let roots = model.treeRoots(networkMounts: [mount])

        #expect(roots.contains { $0.path == "/" }, "«Этот Mac» — корень")
        #expect(roots.contains { $0.path == mount.path })
    }

    @Test("папка вне известных корней дерево не трогает")
    func revealOutsideRootsDoesNothing() {
        let model = SidebarModel()
        let root = URL(fileURLWithPath: "/Volumes/Данные")

        model.reveal(URL(fileURLWithPath: "/Users/alex/Documents"), roots: [root])

        #expect(!model.isExpanded(URL(fileURLWithPath: "/Users/alex")))
        #expect(!model.isExpanded(root))
    }

    /// Папка «/Volumes/Данные2» не лежит внутри «/Volumes/Данные», хотя её путь
    /// начинается с той же строки — сравнение идёт по компонентам, а не префиксом.
    @Test("совпадение начала пути не считается вложенностью")
    func prefixIsNotContainment() {
        let model = SidebarModel()
        let root = URL(fileURLWithPath: "/Volumes/Данные")

        model.reveal(URL(fileURLWithPath: "/Volumes/Данные2/Отчёт"), roots: [root])

        #expect(!model.isExpanded(root))
        #expect(!model.isExpanded(URL(fileURLWithPath: "/Volumes/Данные2")))
    }

    @Test("хвостовой слэш не мешает определить раскрытие")
    func expansionIgnoresTrailingSlash() {
        let model = SidebarModel()

        model.toggleExpansion(URL(fileURLWithPath: "/Users/alex/"))

        #expect(model.isExpanded(URL(fileURLWithPath: "/Users/alex")))
    }
}
