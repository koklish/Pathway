import Foundation
import Testing

@testable import PathwayCore

@Suite("Разбор пути из адресной строки")
struct PathInputTests {
    @Test("обычный путь остаётся собой")
    func plainPath() {
        #expect(PathInput.resolve("/Users/tester/Documents")?.path == "/Users/tester/Documents")
    }

    @Test("тильда раскрывается в домашнюю папку")
    func expandsTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        #expect(PathInput.resolve("~/Documents")?.path == "\(home)/Documents")
    }

    @Test("пустая строка не даёт пути")
    func rejectsEmpty() {
        #expect(PathInput.resolve("   ") == nil)
    }

    // MARK: - UNC

    @Test("UNC-путь ведёт в точку монтирования тома")
    func resolvesUNCToMountPoint() {
        // Смонтированные тома ищутся по адресу; в тесте подменяем поиск.
        let target = PathInput.resolve(
            #"\\samba.ip.pro\MAIN\Проекты"#,
            mountPointForShare: { host, share in
                host == "samba.ip.pro" && share == "MAIN"
                    ? URL(fileURLWithPath: "/Volumes/MAIN") : nil
            }
        )

        #expect(target?.path == "/Volumes/MAIN/Проекты")
    }

    @Test("UNC без вложенной папки ведёт в корень тома")
    func resolvesUNCRoot() {
        let target = PathInput.resolve(
            #"\\samba.ip.pro\MAIN"#,
            mountPointForShare: { _, _ in URL(fileURLWithPath: "/Volumes/MAIN") }
        )

        #expect(target?.path == "/Volumes/MAIN")
    }

    @Test("UNC неподключённого тома не даёт пути")
    func unmountedShareReturnsNil() {
        let target = PathInput.resolve(
            #"\\other.local\Архив"#,
            mountPointForShare: { _, _ in nil }
        )

        #expect(target == nil)
    }

    @Test("smb-адрес тоже понимается")
    func resolvesSMBURL() {
        let target = PathInput.resolve(
            "smb://samba.ip.pro/MAIN/Проекты",
            mountPointForShare: { host, share in
                host == "samba.ip.pro" && share == "MAIN"
                    ? URL(fileURLWithPath: "/Volumes/MAIN") : nil
            }
        )

        #expect(target?.path == "/Volumes/MAIN/Проекты")
    }

    @Test("UNC только с именем сервера не даёт пути")
    func serverOnlyReturnsNil() {
        #expect(PathInput.resolve(#"\\samba.ip.pro"#, mountPointForShare: { _, _ in nil }) == nil)
    }
}
