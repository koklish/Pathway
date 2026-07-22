import Foundation
import Testing

@testable import PathwayCore

@Suite("ServerAddress — разбор адреса сервера")
struct ServerAddressTests {
    @Test("привычная запись «//host» получает схему smb по умолчанию")
    func parsesDoubleSlashForm() {
        let address = ServerAddress.parse("//samba.ip.pro")

        #expect(address?.scheme == "smb")
        #expect(address?.host == "samba.ip.pro")
        #expect(address?.share == "")
        #expect(address?.url.absoluteString == "smb://samba.ip.pro")
    }

    @Test("Windows-нотация «\\\\host» разбирается как smb")
    func parsesWindowsUNC() {
        let address = ServerAddress.parse(#"\\samba.ip.pro"#)

        #expect(address?.scheme == "smb")
        #expect(address?.host == "samba.ip.pro")
        #expect(address?.share == "")
    }

    @Test("Windows-нотация с ресурсом разбирается целиком")
    func parsesWindowsUNCWithShare() {
        let address = ServerAddress.parse(#"\\samba.ip.pro\Общие"#)

        #expect(address?.host == "samba.ip.pro")
        #expect(address?.share == "Общие")
        #expect(address?.displayName == "Общие (samba.ip.pro)")
    }

    @Test("Windows-нотация по IP с вложенным путём")
    func parsesWindowsUNCByIP() {
        let address = ServerAddress.parse(#"\\192.168.1.50\share\docs"#)

        #expect(address?.host == "192.168.1.50")
        #expect(address?.share == "share/docs")
        #expect(address?.url.absoluteString == "smb://192.168.1.50/share/docs")
    }

    @Test("голый IP считается адресом")
    func parsesBareIP() {
        #expect(ServerAddress.parse("192.168.1.50")?.host == "192.168.1.50")
    }

    @Test("голый хост без слэшей тоже считается адресом")
    func parsesBareHost() {
        let address = ServerAddress.parse("nas-office.local")

        #expect(address?.scheme == "smb")
        #expect(address?.host == "nas-office.local")
    }

    @Test("явная схема сохраняется вместе с путём к ресурсу")
    func parsesExplicitScheme() {
        let address = ServerAddress.parse("ftp://backup.company.ru/archive")

        #expect(address?.scheme == "ftp")
        #expect(address?.host == "backup.company.ru")
        #expect(address?.share == "archive")
        #expect(address?.url.absoluteString == "ftp://backup.company.ru/archive")
    }

    @Test("вложенный путь к ресурсу сохраняется целиком")
    func parsesNestedShare() {
        let address = ServerAddress.parse("https://cloud.company.ru/webdav/docs")

        #expect(address?.share == "webdav/docs")
    }

    @Test("логин в адресе отбрасывается — учётные данные вводятся отдельно")
    func stripsUserInfo() {
        let address = ServerAddress.parse("smb://alex@nas.local/Общие")

        #expect(address?.host == "nas.local")
        #expect(address?.share == "Общие")
    }

    @Test("кириллица в имени ресурса экранируется, URL остаётся валидным")
    func encodesCyrillicShare() throws {
        let address = try #require(ServerAddress.parse("smb://nas.local/Общие"))

        #expect(address.url.absoluteString == "smb://nas.local/%D0%9E%D0%B1%D1%89%D0%B8%D0%B5")
    }

    @Test("экранированный адрес разбирается обратно в исходный ресурс")
    func decodesPercentEncodedShare() throws {
        // Так адрес приходит из getmntinfo: система отдаёт f_mntfromname уже
        // экранированным. Без декодирования share становится «%D0%9E%D0%B1…»,
        // и такой адрес не совпадает с закладкой на тот же ресурс.
        let address = try #require(ServerAddress.parse("//nas.local/%D0%9E%D0%B1%D1%89%D0%B8%D0%B5"))

        #expect(address.share == "Общие")
        #expect(address.displayName == "Общие (nas.local)")
    }

    @Test("разбор своего же URL возвращает тот же адрес")
    func roundTripsThroughURL() throws {
        let original = try #require(ServerAddress.parse("smb://nas.local/Общие"))
        let reparsed = try #require(ServerAddress.parse(original.url.absoluteString))

        #expect(reparsed == original)
        #expect(reparsed.url.absoluteString == original.url.absoluteString)
    }

    @Test("регистр схемы не имеет значения")
    func schemeIsCaseInsensitive() {
        #expect(ServerAddress.parse("SMB://nas.local")?.scheme == "smb")
    }

    @Test("пустой ввод и незнакомая схема адресом не являются")
    func rejectsInvalidInput() {
        #expect(ServerAddress.parse("") == nil)
        #expect(ServerAddress.parse("   ") == nil)
        #expect(ServerAddress.parse("//") == nil)
        #expect(ServerAddress.parse("carrier-pigeon://nas.local") == nil)
    }

    @Test("имя для показа состоит из ресурса и хоста")
    func buildsDisplayName() {
        #expect(ServerAddress.parse("smb://nas-office.local/Общие")?.displayName == "Общие (nas-office.local)")
        #expect(ServerAddress.parse("smb://nas-office.local")?.displayName == "nas-office.local")
        #expect(ServerAddress.parse("https://cloud.company.ru/webdav/Docs")?.displayName == "Docs (cloud.company.ru)")
    }
}
