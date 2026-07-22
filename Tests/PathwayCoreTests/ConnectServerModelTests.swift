import Foundation
import Testing

@testable import PathwayCore

@MainActor
private func makeModel(
    _ behaviour: RecordingMounter.Behaviour,
    shares: [Share] = [],
    openPorts: Set<UInt16> = [445]
) -> (ConnectServerModel, RecordingMounter, ServerConnection) {
    // Изолированный UserDefaults, чтобы тесты не трогали настройки пользователя.
    let suite = "tests.connect.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let mounter = RecordingMounter(behaviour)
    let connection = ServerConnection(
        bookmarks: ServerBookmarks(defaults: defaults),
        credentials: InMemoryCredentialStore(),
        mounter: mounter,
        mounted: MountedServers()
    )
    // Фейковый браузер и заглушка проб обязательны: иначе тест пойдёт в сеть.
    let model = ConnectServerModel(
        connection: connection,
        browser: FakeShareBrowser(shares: shares),
        probe: ProtocolProbe(prober: StubPortProber(open: openPorts))
    )
    return (model, mounter, connection)
}

@Suite("ConnectServerModel — диалог подключения к серверу")
@MainActor
struct ConnectServerModelTests {
    @Test("сервер, требующий вход, переводит диалог на экран авторизации")
    func movesToCredentialsStep() async {
        let (model, _, _) = makeModel(.needsAuth)
        // Папка указана явно: адрес без неё теперь ведёт на выбор папки.
        model.addressText = "//samba.ip.pro/MAIN"

        await model.submit()

        #expect(model.step == .credentials(ServerAddress(scheme: "smb", host: "samba.ip.pro", share: "MAIN")))
        #expect(model.authenticatingHost == "samba.ip.pro")
    }

    // MARK: - Определение протокола

    @Test("голый IP с открытым FTP ведёт на ввод логина, а не на выбор папок")
    func bareIPWithFTPGoesToCredentials() async {
        let (model, _, _) = makeModel(.needsAuth, openPorts: [21])
        model.addressText = "31.31.196.75"

        await model.submit()

        // Не .shares: у FTP нет понятия шары, smbutil про него не знает.
        #expect(model.step == .credentials(ServerAddress(scheme: "ftp", host: "31.31.196.75", share: "")))
    }

    @Test("FTP не пробует гостевой вход до ввода логина")
    func ftpDoesNotProbeGuestMount() async {
        let (model, mounter, _) = makeModel(.needsAuth, openPorts: [21])
        model.addressText = "31.31.196.75"

        await model.submit()

        // Ни одной попытки монтирования: анонимный вход на FTP закрыт, и
        // NetFS на отказ показывает собственный диалог авторизации вместо
        // внятного EACCES. Нажатие «Отменить» в нём возвращает -128, и
        // пользователь видит «ошибка -128» вместо своей формы входа.
        #expect(mounter.callCount == 0)
    }

    @Test("после ввода логина FTP монтируется с учётными данными")
    func ftpMountsWithCredentials() async {
        let point = URL(fileURLWithPath: "/Volumes/FTP")
        let (model, mounter, _) = makeModel(.mounted(point), openPorts: [21])
        model.addressText = "31.31.196.75"
        await model.submit()

        model.username = "u3371448"
        model.password = "a03WiT71hB12uZJi"
        await model.submit()

        #expect(mounter.lastUser == "u3371448")
        #expect(mounter.lastGuest == false)
    }

    @Test("FTP предлагает вход по логину, а не гостем")
    func ftpDefaultsToRegisteredLogin() async {
        let (model, _, _) = makeModel(.needsAuth, openPorts: [21])
        model.addressText = "31.31.196.75"

        await model.submit()

        // Анонимный вход на FTP почти всегда закрыт: предложенный гость
        // дал бы гарантированный провал первой попытки.
        #expect(model.login == .registered)
    }

    @Test("голый хост с открытым SMB показывает список папок")
    func bareHostWithSMBListsShares() async {
        let (model, _, _) = makeModel(.needsAuth, shares: [Share(name: "MAIN")], openPorts: [445])
        model.addressText = "samba.ip.pro"

        await model.submit()

        #expect(model.step == .shares(host: "samba.ip.pro"))
    }

    @Test("AFP ведёт на ввод логина с гостевым входом по умолчанию")
    func afpGoesToCredentialsAsGuest() async {
        let (model, _, _) = makeModel(.needsAuth, openPorts: [548])
        model.addressText = "mac.local"

        await model.submit()

        #expect(model.step == .credentials(ServerAddress(scheme: "afp", host: "mac.local", share: "")))
        #expect(model.login == .guest)
    }

    @Test("хост без открытых портов даёт ошибку, не уходя с экрана адреса")
    func unreachableHostStaysOnAddress() async {
        let (model, mounter, _) = makeModel(.needsAuth, openPorts: [])
        model.addressText = "192.0.2.1"

        await model.submit()

        #expect(model.step == .address)
        #expect(model.errorMessage != nil)
        // Монтировать неизвестный протокол не пытаемся.
        #expect(mounter.callCount == 0)
    }

    @Test("явная схема в адресе пробу портов не запускает")
    func explicitSchemeSkipsProbe() async {
        let prober = StubPortProber(open: [445])
        let suite = "tests.connect.\(UUID().uuidString)"
        let connection = ServerConnection(
            bookmarks: ServerBookmarks(defaults: UserDefaults(suiteName: suite)!),
            credentials: InMemoryCredentialStore(),
            mounter: RecordingMounter(.needsAuth),
            mounted: MountedServers()
        )
        let model = ConnectServerModel(
            connection: connection,
            browser: FakeShareBrowser(shares: []),
            probe: ProtocolProbe(prober: prober)
        )
        model.addressText = "ftp://31.31.196.75/pub"

        await model.submit()

        // Схема названа пользователем — спрашивать сеть не о чем.
        #expect(await prober.probed.isEmpty)
        #expect(model.step == .credentials(ServerAddress(scheme: "ftp", host: "31.31.196.75", share: "pub")))
    }

    @Test("UNC-адрес пробу портов не запускает")
    func uncSkipsProbe() async {
        let prober = StubPortProber(open: [21])
        let suite = "tests.connect.\(UUID().uuidString)"
        let connection = ServerConnection(
            bookmarks: ServerBookmarks(defaults: UserDefaults(suiteName: suite)!),
            credentials: InMemoryCredentialStore(),
            mounter: RecordingMounter(.needsAuth),
            mounted: MountedServers()
        )
        let model = ConnectServerModel(
            connection: connection,
            browser: FakeShareBrowser(shares: []),
            probe: ProtocolProbe(prober: prober)
        )
        model.addressText = #"\\samba.ip.pro\MAIN"#

        await model.submit()

        // Открытый 21 порт не должен превратить UNC-адрес в FTP.
        #expect(await prober.probed.isEmpty)
        #expect(model.step == .credentials(ServerAddress(scheme: "smb", host: "samba.ip.pro", share: "MAIN")))
    }

    @Test("кнопка обещает список папок только там, где он есть")
    func submitTitleFollowsKnownScheme() {
        let (model, _, _) = makeModel(.needsAuth)

        model.addressText = "smb://samba.ip.pro"
        #expect(model.submitTitle == "Показать папки")

        // Протокол ещё не известен: обещать папки нельзя, у FTP их нет.
        model.addressText = "31.31.196.75"
        #expect(model.submitTitle == "Подключиться")

        model.addressText = "ftp://31.31.196.75"
        #expect(model.submitTitle == "Подключиться")

        model.addressText = "smb://samba.ip.pro/MAIN"
        #expect(model.submitTitle == "Подключиться")
    }

    @Test("адрес без папки показывает список папок сервера")
    func addressWithoutShareListsShares() async {
        let (model, mounter, _) = makeModel(.needsAuth, shares: [
            Share(name: "MAIN", comment: "Common share"),
            Share(name: "Спецификации"),
        ])
        model.addressText = "//samba.ip.pro"

        await model.submit()

        #expect(model.step == .shares(host: "samba.ip.pro"))
        #expect(model.shares.map(\.name) == ["MAIN", "Спецификации"])
        // Ничего не смонтировали: сначала пусть выберут папку.
        #expect(mounter.callCount == 0)
    }

    @Test("выбор папки из списка подключает именно её")
    func selectingShareConnectsToIt() async {
        let point = URL(fileURLWithPath: "/Volumes/MAIN")
        let (model, mounter, _) = makeModel(.mounted(point), shares: [Share(name: "MAIN")])
        model.addressText = "//samba.ip.pro"
        await model.submit()

        var opened: URL?
        model.onMounted = { opened = $0 }
        await model.selectShare(Share(name: "MAIN"), host: "samba.ip.pro")

        #expect(opened == point)
        #expect(mounter.callCount == 1)
    }

    @Test("«Назад» со списка папок очищает его")
    func goingBackClearsShares() async {
        let (model, _, _) = makeModel(.needsAuth, shares: [Share(name: "MAIN")])
        model.addressText = "//samba.ip.pro"
        await model.submit()

        model.goBackToAddress()

        #expect(model.step == .address)
        #expect(model.shares.isEmpty)
    }

    @Test("успешное подключение отдаёт точку монтирования и запоминает сервер")
    func mountsAndRemembers() async {
        let mountPoint = URL(fileURLWithPath: "/Volumes/Общие")
        let (model, _, _) = makeModel(.mounted(mountPoint))
        model.addressText = "smb://nas-office.local/Общие"

        var opened: URL?
        model.onMounted = { opened = $0 }
        await model.submit()

        #expect(opened == mountPoint)
        #expect(model.bookmarks.items.map(\.address) == ["smb://nas-office.local/%D0%9E%D0%B1%D1%89%D0%B8%D0%B5"])
        #expect(model.bookmarks.items.first?.name == "Общие (nas-office.local)")
    }

    @Test("на экране авторизации логин и пароль уходят в монтирование")
    func passesCredentials() async {
        let (model, mounter, _) = makeModel(.needsAuth)
        model.addressText = "smb://backup.company.ru/archive"
        await model.submit()

        mounter.behaviour = .mounted(URL(fileURLWithPath: "/Volumes/archive"))
        model.login = .registered
        model.username = "alex"
        model.password = "секрет"
        await model.submit()

        #expect(mounter.lastUser == "alex")
        #expect(mounter.lastPassword == "секрет")
        #expect(mounter.lastGuest == false)
    }

    @Test("доменный логин уходит в монтирование без изменений")
    func passesDomainLoginVerbatim() async {
        let (model, mounter, _) = makeModel(.needsAuth)
        model.addressText = #"\\samba.ip.pro\Общие"#
        await model.submit()

        mounter.behaviour = .mounted(URL(fileURLWithPath: "/Volumes/Общие"))
        model.username = #"COMPANY\alex"#
        model.password = "секрет"
        await model.submit()

        // Обратный слэш здесь — часть логина, а не разделитель пути.
        #expect(mounter.lastUser == #"COMPANY\alex"#)
    }

    @Test("Windows-нотация адреса доходит до монтирования")
    func mountsWindowsStyleAddress() async {
        let mountPoint = URL(fileURLWithPath: "/Volumes/Общие")
        let (model, _, _) = makeModel(.mounted(mountPoint))
        model.addressText = #"\\samba.ip.pro\Общие"#

        var opened: URL?
        model.onMounted = { opened = $0 }
        await model.submit()

        #expect(opened == mountPoint)
        #expect(model.bookmarks.items.first?.name == "Общие (samba.ip.pro)")
    }

    @Test("гостевой вход не передаёт учётные данные")
    func guestLoginSendsNoCredentials() async {
        let (model, mounter, _) = makeModel(.needsAuth)
        model.addressText = "smb://nas.local/pub"
        await model.submit()

        mounter.behaviour = .mounted(URL(fileURLWithPath: "/Volumes/pub"))
        model.login = .guest
        model.username = "не должен уйти"
        await model.submit()

        #expect(mounter.lastGuest == true)
        #expect(mounter.lastUser == nil)
        #expect(mounter.lastPassword == nil)
    }

    @Test("после успешного входа пароль не остаётся в памяти модели")
    func clearsPasswordAfterMount() async {
        let (model, mounter, _) = makeModel(.needsAuth)
        model.addressText = "smb://nas.local/pub"
        await model.submit()

        mounter.behaviour = .mounted(URL(fileURLWithPath: "/Volumes/pub"))
        model.username = "alex"
        model.password = "секрет"
        await model.submit()

        #expect(model.password.isEmpty)
    }

    @Test("недоступный сервер показывает понятную ошибку и не запоминается")
    func showsFriendlyError() async {
        let (model, _, _) = makeModel(.failure(Int32(EHOSTUNREACH)))
        model.addressText = "//samba.ip.pro/MAIN"

        await model.submit()

        #expect(model.errorMessage?.contains("samba.ip.pro") == true)
        #expect(model.errorMessage?.contains("недоступен") == true)
        #expect(model.bookmarks.items.isEmpty)
    }

    @Test("неразбираемый адрес не доходит до монтирования")
    func rejectsGarbageAddress() async {
        let (model, mounter, _) = makeModel(.mounted(URL(fileURLWithPath: "/Volumes/x")))
        model.addressText = "//"

        await model.submit()

        #expect(mounter.callCount == 0)
        #expect(model.errorMessage != nil)
        #expect(model.canSubmit == false)
    }

    @Test("«Назад» возвращает к адресу и стирает введённый пароль")
    func goBackClearsPassword() async {
        let (model, _, _) = makeModel(.needsAuth)
        model.addressText = "smb://nas.local/pub"
        await model.submit()
        model.password = "секрет"

        model.goBackToAddress()

        #expect(model.step == .address)
        #expect(model.password.isEmpty)
    }

    @Test("клик по избранному подставляет его адрес в поле")
    func selectingBookmarkFillsField() {
        let (model, _, _) = makeModel(.needsAuth)

        model.selectBookmark(ServerBookmark(address: "ftp://backup.company.ru/archive", name: "archive"))

        #expect(model.addressText == "ftp://backup.company.ru/archive")
    }

    @Test("избранное переживает пересоздание и не двоится при повторном подключении")
    func bookmarksPersistAndDeduplicate() {
        let suite = "tests.bookmarks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let server = ServerAddress(scheme: "smb", host: "nas.local", share: "Общие")
        let other = ServerAddress(scheme: "ftp", host: "backup.ru", share: "arch")

        let first = ServerBookmarks(defaults: defaults)
        first.remember(server)
        first.remember(other)
        first.remember(server)   // повторное подключение — та же запись, но наверх

        let reloaded = ServerBookmarks(defaults: defaults)

        #expect(reloaded.items.count == 2)
        #expect(reloaded.items.first?.address == server.url?.absoluteString)
    }
}
