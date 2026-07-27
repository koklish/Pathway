import Foundation
import Testing

@testable import PathwayCore

@Suite("ServerAddress — разбор адреса сервера")
struct ServerAddressTests {
    @Test("привычная запись «//host» означает smb")
    func parsesDoubleSlashForm() {
        let address = ServerAddress.parse("//samba.ip.pro")

        #expect(address?.scheme == "smb")
        #expect(address?.host == "samba.ip.pro")
        #expect(address?.share == "")
        #expect(address?.url?.absoluteString == "smb://samba.ip.pro")
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
        #expect(address?.url?.absoluteString == "smb://192.168.1.50/share/docs")
    }

    @Test("голый IP считается адресом, но протокол остаётся неизвестным")
    func parsesBareIP() {
        let address = ServerAddress.parse("31.31.196.75")

        #expect(address?.host == "31.31.196.75")
        // Не smb: панель хостинга даёт голый IP, и подставленная схема выдала бы
        // догадку за факт. Протокол определяет ProtocolProbe.
        #expect(address?.scheme == nil)
    }

    @Test("голый хост без слэшей тоже считается адресом без протокола")
    func parsesBareHost() {
        let address = ServerAddress.parse("nas-office.local")

        #expect(address?.scheme == nil)
        #expect(address?.host == "nas-office.local")
    }

    @Test("адрес без схемы нельзя превратить в URL")
    func hasNoURLWithoutScheme() {
        // Смонтировать неизвестный протокол нельзя, и тип это выражает:
        // вызывающий обязан сначала определить схему.
        #expect(ServerAddress.parse("31.31.196.75")?.url == nil)
    }

    @Test("схема, приписанная к адресу, даёт готовый URL")
    func adoptsDetectedScheme() throws {
        let address = try #require(ServerAddress.parse("31.31.196.75"))
        let resolved = address.with(scheme: "ftp")

        #expect(resolved.scheme == "ftp")
        #expect(resolved.url?.absoluteString == "ftp://31.31.196.75")
    }

    @Test("явная схема сохраняется вместе с путём к ресурсу")
    func parsesExplicitScheme() {
        let address = ServerAddress.parse("ftp://backup.company.ru/archive")

        #expect(address?.scheme == "ftp")
        #expect(address?.host == "backup.company.ru")
        #expect(address?.share == "archive")
        #expect(address?.url?.absoluteString == "ftp://backup.company.ru/archive")
    }

    @Test("вложенный путь к ресурсу сохраняется целиком")
    func parsesNestedShare() {
        let address = ServerAddress.parse("https://cloud.company.ru/webdav/docs")

        #expect(address?.share == "webdav/docs")
    }

    @Test("логин в адресе сохраняется — он часть идентичности сервера")
    func keepsUserInfo() {
        let address = ServerAddress.parse("smb://alex@nas.local/Общие")

        #expect(address?.host == "nas.local")
        #expect(address?.share == "Общие")
        #expect(address?.user == "alex")
    }

    @Test("адрес без логина даёт nil, а не пустую строку")
    func missingUserIsNil() {
        // Пустая строка сделала бы «smb://@nas.local» валидным ключом, отличным
        // от «smb://nas.local», и закладки разъехались бы на пустом месте.
        #expect(ServerAddress.parse("smb://nas.local/Общие")?.user == nil)
        #expect(ServerAddress.parse("smb://@nas.local/Общие")?.user == nil)
    }

    @Test("логин уцелел при разборе адреса от getmntinfo")
    func keepsUserFromSystemMount() throws {
        // f_mntfromname для SMB имеет вид «//ivan@nas/share»: логин система
        // отдаёт сама, и раньше он терялся на разборе — том, подключённый
        // мимо приложения, не отличался от подключённого другим логином.
        let address = try #require(ServerAddress.parse("//ivan@nas.local/MAIN"))

        #expect(address.user == "ivan")
        #expect(address.host == "nas.local")
    }

    @Test("логин возвращается обратно в строку URL")
    func putsUserBackIntoURL() throws {
        let address = try #require(ServerAddress.parse("smb://alex@nas.local/Общие"))

        #expect(address.url?.absoluteString.hasPrefix("smb://alex@nas.local/") == true)
    }

    @Test("Windows-нотация с логином тоже отдаёт логин")
    func keepsUserFromUNC() throws {
        let address = try #require(ServerAddress.parse(#"\\alex@nas.local\Общие"#))

        #expect(address.user == "alex")
        #expect(address.scheme == "smb")
    }

    @Test("собака в имени ресурса логином не считается")
    func atSignInSharePathIsNotUser() throws {
        // Искать логин по всей строке нельзя: «отчёт@2024» — законное имя папки,
        // и хостом стал бы «2024».
        let address = try #require(ServerAddress.parse("smb://nas.local/отчёт@2024"))

        #expect(address.user == nil)
        #expect(address.host == "nas.local")
        #expect(address.share == "отчёт@2024")
    }

    @Test("ключом служит полный адрес с логином, а не только хост и ресурс")
    func keyIncludesUser() throws {
        let ivan = try #require(ServerAddress.parse("smb://ivan@nas.local/MAIN"))
        let petr = try #require(ServerAddress.parse("smb://petr@nas.local/MAIN"))
        let anonymous = try #require(ServerAddress.parse("smb://nas.local/MAIN"))

        #expect(ivan.key != petr.key)
        #expect(ivan.key != anonymous.key)
        #expect(ivan.key == "smb://ivan@nas.local/MAIN")
    }

    @Test("одинаковый логин даёт совпадающий ключ")
    func sameUserSameKey() throws {
        let first = try #require(ServerAddress.parse("smb://ivan@nas.local/MAIN"))
        let second = try #require(ServerAddress.parse("smb://ivan@nas.local/MAIN"))

        #expect(first.key == second.key)
        #expect(first == second)
    }

    @Test("адрес без логина сохраняет прежний ключ — старые закладки не осиротели")
    func keyUnchangedWithoutUser() throws {
        // Формат ключа у записей без логина обязан совпасть с сохранённым до
        // появления поля: иначе закладки и пароли коллег перестали бы находиться.
        let address = try #require(ServerAddress.parse("smb://nas.local/Общие"))

        #expect(address.key == "smb://nas.local/%D0%9E%D0%B1%D1%89%D0%B8%D0%B5")
    }

    @Test("кириллица в имени ресурса экранируется, URL остаётся валидным")
    func encodesCyrillicShare() throws {
        let address = try #require(ServerAddress.parse("smb://nas.local/Общие"))

        #expect(address.url?.absoluteString == "smb://nas.local/%D0%9E%D0%B1%D1%89%D0%B8%D0%B5")
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
        let url = try #require(original.url)
        let reparsed = try #require(ServerAddress.parse(url.absoluteString))

        #expect(reparsed == original)
        #expect(reparsed.url?.absoluteString == url.absoluteString)
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
