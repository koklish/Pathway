import Foundation
import Testing

@testable import PathwayCore

@MainActor
private func makeModel(
    _ behaviour: RecordingMounter.Behaviour,
    shares: [Share] = []
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
    // Фейковый браузер обязателен: иначе тест пойдёт в настоящую сеть.
    let model = ConnectServerModel(connection: connection, browser: FakeShareBrowser(shares: shares))
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
        #expect(reloaded.items.first?.address == server.url.absoluteString)
    }
}
