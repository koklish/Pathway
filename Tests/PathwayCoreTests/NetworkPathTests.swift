import Foundation
import Testing

@testable import PathwayCore

@Suite("UNC-путь сетевого тома")
struct NetworkPathTests {
    private let mountPoint = URL(fileURLWithPath: "/Volumes/MAIN")

    @Test("точка монтирования превращается в UNC-путь")
    func buildsUNCForMountRoot() {
        let unc = NetworkPath.unc(
            for: mountPoint,
            mountPoint: mountPoint,
            remountURL: URL(string: "smb://samba.ip.pro/MAIN")
        )

        #expect(unc == #"\\samba.ip.pro\MAIN"#)
    }

    @Test("вложенная папка дописывается через обратные слэши")
    func appendsNestedPath() {
        let unc = NetworkPath.unc(
            for: URL(fileURLWithPath: "/Volumes/MAIN/Проекты/Отчёт"),
            mountPoint: mountPoint,
            remountURL: URL(string: "smb://samba.ip.pro/MAIN")
        )

        #expect(unc == #"\\samba.ip.pro\MAIN\Проекты\Отчёт"#)
    }

    @Test("учётные данные из адреса не попадают в путь")
    func stripsCredentials() {
        // macOS отдаёт адрес перемонтирования вместе с логином — показывать его нельзя.
        let unc = NetworkPath.unc(
            for: mountPoint,
            mountPoint: mountPoint,
            remountURL: URL(string: "smb://GUEST:@samba.ip.pro/MAIN")
        )

        #expect(unc == #"\\samba.ip.pro\MAIN"#)
    }

    @Test("логин с паролем тоже вырезается целиком")
    func stripsUserAndPassword() {
        let unc = NetworkPath.unc(
            for: mountPoint,
            mountPoint: mountPoint,
            remountURL: URL(string: "smb://user:secret@nas.local/Общие")
        )

        #expect(unc == #"\\nas.local\Общие"#)
    }

    @Test("нестандартный порт сохраняется")
    func keepsCustomPort() {
        let unc = NetworkPath.unc(
            for: mountPoint,
            mountPoint: mountPoint,
            remountURL: URL(string: "smb://samba.ip.pro:4455/MAIN")
        )

        #expect(unc == #"\\samba.ip.pro:4455\MAIN"#)
    }

    @Test("процентное кодирование в имени раскодируется")
    func decodesPercentEncoding() {
        let unc = NetworkPath.unc(
            for: mountPoint,
            mountPoint: mountPoint,
            remountURL: URL(string: "smb://nas.local/Общая%20папка")
        )

        #expect(unc == #"\\nas.local\Общая папка"#)
    }

    @Test("без адреса перемонтирования UNC не строится")
    func returnsNilWithoutRemountURL() {
        #expect(NetworkPath.unc(for: mountPoint, mountPoint: mountPoint, remountURL: nil) == nil)
    }

    @Test("адрес без хоста не даёт UNC")
    func returnsNilWithoutHost() {
        let unc = NetworkPath.unc(
            for: mountPoint,
            mountPoint: mountPoint,
            remountURL: URL(string: "smb:///MAIN")
        )

        #expect(unc == nil)
    }

    @Test("путь вне точки монтирования не превращается в UNC")
    func returnsNilForPathOutsideMount() {
        // Защита от случая, когда точка монтирования определена неверно.
        let unc = NetworkPath.unc(
            for: URL(fileURLWithPath: "/Users/tester/Documents"),
            mountPoint: mountPoint,
            remountURL: URL(string: "smb://samba.ip.pro/MAIN")
        )

        #expect(unc == nil)
    }

    @Test("похожее имя тома не считается вложенным путём")
    func doesNotMatchSiblingVolumeWithSharedPrefix() {
        // «/Volumes/MAIN2» начинается с «/Volumes/MAIN», но это другой том.
        let unc = NetworkPath.unc(
            for: URL(fileURLWithPath: "/Volumes/MAIN2/Файл"),
            mountPoint: mountPoint,
            remountURL: URL(string: "smb://samba.ip.pro/MAIN")
        )

        #expect(unc == nil)
    }
}
