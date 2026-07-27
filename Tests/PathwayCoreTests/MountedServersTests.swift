import Foundation
import Testing

@testable import PathwayCore

@Suite("Подключённые серверы")
@MainActor
struct MountedServersTests {
    private let server = ServerAddress(scheme: "smb", host: "nas.local", share: "Общие")
    private let other = ServerAddress(scheme: "smb", host: "other.local", share: "Архив")

    @Test("после подключения сервер числится смонтированным")
    func remembersMountPoint() {
        let servers = MountedServers()
        let point = URL(fileURLWithPath: "/Volumes/Общие")

        servers.remember(server, at: point)

        #expect(servers.isMounted(server))
        #expect(servers.mountPoint(for: server)?.path == point.path)
    }

    @Test("незнакомый сервер не считается подключённым")
    func unknownServerIsNotMounted() {
        let servers = MountedServers()

        #expect(!servers.isMounted(server))
        #expect(servers.mountPoint(for: server) == nil)
    }

    @Test("после отключения сервер перестаёт числиться")
    func forgetsOnUnmount() {
        let servers = MountedServers()
        servers.remember(server, at: URL(fileURLWithPath: "/Volumes/Общие"))

        servers.forget(server)

        #expect(!servers.isMounted(server))
    }

    @Test("серверы учитываются независимо")
    func serversAreIndependent() {
        let servers = MountedServers()

        servers.remember(server, at: URL(fileURLWithPath: "/Volumes/Общие"))
        servers.remember(other, at: URL(fileURLWithPath: "/Volumes/Архив"))
        servers.forget(server)

        #expect(!servers.isMounted(server))
        #expect(servers.isMounted(other))
    }

    @Test("исчезнувший из /Volumes том перестаёт числиться подключённым")
    func dropsVanishedVolumes() throws {
        let servers = MountedServers()
        // Точка монтирования, которой заведомо нет на диске.
        servers.remember(server, at: URL(fileURLWithPath: "/Volumes/нет-такого-\(UUID().uuidString)"))

        servers.refresh()

        #expect(!servers.isMounted(server))
    }

    @Test("дерево папок не показывает сетевые тома внутри /Volumes")
    func treeHidesNetworkVolumes() async {
        let model = BrowserModel(path: URL(fileURLWithPath: "/"))
        let servers = MountedServers()
        servers.adoptExistingMounts()

        let children = await model.subdirectoriesAsync(of: URL(fileURLWithPath: "/Volumes"))
        let names = Set(children.map(\.name))

        // Сетевой том живёт в секции «Сеть»; в дереве «Этот Mac» он был бы дублем.
        for volume in servers.networkVolumes {
            #expect(!names.contains(volume.mountPoint.lastPathComponent),
                    "сетевой том \(volume.mountPoint.lastPathComponent) не должен быть в дереве")
        }
    }

    @Test("находит тома, смонтированные мимо приложения")
    func discoversExternallyMountedVolumes() {
        let servers = MountedServers()

        servers.adoptExistingMounts()

        // На машине без сетевых томов список пуст — это нормальный исход.
        for volume in servers.networkVolumes {
            #expect(volume.mountPoint.path.hasPrefix("/Volumes/"))
            #expect(!volume.server.host.isEmpty)
        }
    }

    @Test("подхваченный том числится подключённым")
    func adoptedVolumeIsMounted() {
        let servers = MountedServers()
        servers.adoptExistingMounts()

        for volume in servers.networkVolumes {
            #expect(servers.isMounted(volume.server))
        }
    }

    @Test("один ресурс, смонтированный дважды, даёт одну строку")
    func duplicateMountsCollapseIntoOneEntry() {
        let servers = MountedServers()
        // Ровно то, что отдаёт система после повторного подключения:
        // //GUEST@samba.ip.pro/MAIN висит и на /Volumes/MAIN, и на /Volumes/MAIN-1.
        servers.adopt([
            MountedServers.NetworkVolume(server: server, mountPoint: URL(fileURLWithPath: "/Volumes/MAIN")),
            MountedServers.NetworkVolume(server: server, mountPoint: URL(fileURLWithPath: "/Volumes/MAIN-1")),
        ])

        #expect(servers.networkVolumes.count == 1)
        #expect(servers.networkVolumes.first?.mountPoint.path == "/Volumes/MAIN")
    }

    @Test("один ресурс под разными учётными записями даёт две строки")
    func differentUsersKeepBothMounts() throws {
        let servers = MountedServers()
        // Так выглядят два одновременных подключения к одному ресурсу: система
        // монтирует их в разные точки, и схлопывать их нельзя — это не следы
        // прошлого подключения, а два живых тома с разными правами.
        let ivan = try #require(ServerAddress.parse("//ivan@samba.ip.pro/MAIN"))
        let petr = try #require(ServerAddress.parse("//petr@samba.ip.pro/MAIN"))

        servers.adopt([
            MountedServers.NetworkVolume(server: ivan, mountPoint: URL(fileURLWithPath: "/Volumes/MAIN")),
            MountedServers.NetworkVolume(server: petr, mountPoint: URL(fileURLWithPath: "/Volumes/MAIN-1")),
        ])

        #expect(servers.networkVolumes.count == 2)
    }

    @Test("каждая учётная запись помнит свою точку монтирования")
    func mountPointIsPerUser() throws {
        let servers = MountedServers()
        let ivan = try #require(ServerAddress.parse("//ivan@samba.ip.pro/MAIN"))
        let petr = try #require(ServerAddress.parse("//petr@samba.ip.pro/MAIN"))

        servers.remember(ivan, at: URL(fileURLWithPath: "/Volumes/MAIN"))
        servers.remember(petr, at: URL(fileURLWithPath: "/Volumes/MAIN-1"))

        #expect(servers.mountPoint(for: ivan)?.path == "/Volumes/MAIN")
        #expect(servers.mountPoint(for: petr)?.path == "/Volumes/MAIN-1")
    }

    @Test("отключение одной учётной записи не забывает вторую")
    func forgettingOneUserKeepsOther() throws {
        let servers = MountedServers()
        let ivan = try #require(ServerAddress.parse("//ivan@samba.ip.pro/MAIN"))
        let petr = try #require(ServerAddress.parse("//petr@samba.ip.pro/MAIN"))
        servers.remember(ivan, at: URL(fileURLWithPath: "/Volumes/MAIN"))
        servers.remember(petr, at: URL(fileURLWithPath: "/Volumes/MAIN-1"))

        servers.forget(ivan)

        #expect(!servers.isMounted(ivan))
        #expect(servers.isMounted(petr))
    }

    @Test("по точке монтирования находится учётная запись тома")
    func findsUserByMountPoint() throws {
        let servers = MountedServers()
        let ivan = try #require(ServerAddress.parse("//ivan@samba.ip.pro/MAIN"))
        let petr = try #require(ServerAddress.parse("//petr@samba.ip.pro/MAIN"))
        servers.adopt([
            MountedServers.NetworkVolume(server: ivan, mountPoint: URL(fileURLWithPath: "/Volumes/MAIN")),
            MountedServers.NetworkVolume(server: petr, mountPoint: URL(fileURLWithPath: "/Volumes/MAIN-1")),
        ])

        // Сопоставление по точке монтирования, а не по имени тома: имена у одного
        // ресурса, подключённого дважды, совпадают, а точки уникальны — их
        // выдаёт система.
        #expect(servers.user(at: URL(fileURLWithPath: "/Volumes/MAIN")) == "ivan")
        #expect(servers.user(at: URL(fileURLWithPath: "/Volumes/MAIN-1")) == "petr")
    }

    @Test("у локального диска учётной записи нет")
    func localVolumeHasNoUser() {
        let servers = MountedServers()

        #expect(servers.user(at: URL(fileURLWithPath: "/")) == nil)
    }

    @Test("адрес от getmntinfo остаётся smb, а не теряет схему")
    func systemMountSourceKeepsSMBScheme() throws {
        // Ровно та форма, в которой система отдаёт f_mntfromname: схемы в ней
        // нет, только «//». Если бы такой адрес разбирался без протокола,
        // смонтированный в Finder том исчез бы из сайдбара.
        let adopted = try #require(ServerAddress.parse("//GUEST@samba.ip.pro/MAIN"))

        #expect(adopted.scheme == "smb")
        #expect(adopted.host == "samba.ip.pro")
        #expect(adopted.share == "MAIN")
    }

    @Test("разные серверы не схлопываются")
    func differentServersStay() {
        let servers = MountedServers()

        servers.adopt([
            MountedServers.NetworkVolume(server: server, mountPoint: URL(fileURLWithPath: "/Volumes/Общие")),
            MountedServers.NetworkVolume(server: other, mountPoint: URL(fileURLWithPath: "/Volumes/Архив")),
        ])

        #expect(servers.networkVolumes.count == 2)
    }

    @Test("точка монтирования берётся из первого вхождения дубля")
    func duplicateMountsKeepFirstPoint() {
        let servers = MountedServers()

        servers.adopt([
            MountedServers.NetworkVolume(server: server, mountPoint: URL(fileURLWithPath: "/Volumes/MAIN")),
            MountedServers.NetworkVolume(server: server, mountPoint: URL(fileURLWithPath: "/Volumes/MAIN-1")),
        ])

        #expect(servers.mountPoint(for: server)?.path == "/Volumes/MAIN")
    }

    @Test("существующий том остаётся подключённым после сверки")
    func keepsExistingVolumes() {
        let servers = MountedServers()
        // /tmp существует всегда — подходит как заведомо живая точка.
        servers.remember(server, at: URL(fileURLWithPath: "/tmp"))

        servers.refresh()

        #expect(servers.isMounted(server))
    }
}
