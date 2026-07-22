import Foundation
import Testing

@testable import PathwayCore

/// Подменяет NetFS: отдаёт заранее заданный результат и запоминает, с чем его позвали.
final class RecordingMounter: Mounting, @unchecked Sendable {
    enum Behaviour {
        case needsAuth
        case mounted(URL)
        case failure(Int32)
    }

    var behaviour: Behaviour
    private(set) var lastUser: String?
    private(set) var lastPassword: String?
    private(set) var lastGuest = false
    private(set) var callCount = 0
    private(set) var unmounted: [URL] = []
    var unmountError: MountError?

    init(_ behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    func mount(_ server: ServerAddress, user: String?, password: String?, guest: Bool) throws -> MountResult {
        callCount += 1
        lastUser = user
        lastPassword = password
        lastGuest = guest

        switch behaviour {
        case .needsAuth: return .authenticationRequired
        case .mounted(let url): return .mounted(url)
        case .failure(let code): throw MountError(code: code, host: server.host)
        }
    }

    func unmount(_ mountPoint: URL) throws {
        if let unmountError { throw unmountError }
        unmounted.append(mountPoint)
    }
}

/// Подменяет smbutil: отдаёт заданный список папок, не трогая сеть.
final class FakeShareBrowser: ShareBrowsing, @unchecked Sendable {
    var shares: [Share]
    var error: (any Error)?
    private(set) var lastUser: String?

    init(shares: [Share] = [], error: (any Error)? = nil) {
        self.shares = shares
        self.error = error
    }

    func shares(of host: String, user: String?, password: String?) throws -> [Share] {
        lastUser = user
        if let error { throw error }
        return shares
    }
}

@MainActor
private func makeConnection(
    _ behaviour: RecordingMounter.Behaviour
) -> (ServerConnection, RecordingMounter, InMemoryCredentialStore, ServerBookmarks) {
    let defaults = UserDefaults(suiteName: "tests.connection.\(UUID().uuidString)")!
    let mounter = RecordingMounter(behaviour)
    let credentials = InMemoryCredentialStore()
    let bookmarks = ServerBookmarks(defaults: defaults)
    let connection = ServerConnection(
        bookmarks: bookmarks,
        credentials: credentials,
        mounter: mounter,
        mounted: MountedServers()
    )
    return (connection, mounter, credentials, bookmarks)
}

@Suite("Подключение к серверу")
@MainActor
struct ServerConnectionTests {
    private let server = ServerAddress(scheme: "smb", host: "nas.local", share: "Общие")

    // MARK: - Приоритет учётных данных

    @Test("сохранённые учётные данные используются без экрана авторизации")
    func savedCredentialsSkipAuthScreen() async throws {
        let (connection, mounter, credentials, _) = makeConnection(.mounted(URL(fileURLWithPath: "/Volumes/Общие")))
        try credentials.save(user: "alex", password: "секрет", for: server)

        let outcome = await connection.connect(to: server)

        #expect(mounter.lastUser == "alex")
        #expect(mounter.lastPassword == "секрет")
        #expect(outcome == .mounted(URL(fileURLWithPath: "/Volumes/Общие")))
    }

    @Test("закладка с гостевым входом подключается гостем")
    func guestBookmarkConnectsAsGuest() async {
        let (connection, mounter, _, bookmarks) = makeConnection(.mounted(URL(fileURLWithPath: "/Volumes/pub")))
        bookmarks.remember(server, isGuest: true)

        _ = await connection.connect(to: server)

        #expect(mounter.lastGuest == true)
        #expect(mounter.lastUser == nil)
    }

    @Test("без сохранённых данных сервер, требующий вход, просит авторизацию")
    func unknownServerAsksForCredentials() async {
        let (connection, _, _, _) = makeConnection(.needsAuth)

        let outcome = await connection.connect(to: server)

        #expect(outcome == .needsCredentials(suggestedUser: nil, reason: .firstTime))
    }

    // MARK: - Устаревший пароль

    @Test("отклонённый сохранённый пароль ведёт на экран входа с подставленным именем")
    func staleCredentialsReturnToLogin() async throws {
        let (connection, _, credentials, _) = makeConnection(.failure(Int32(EAUTH)))
        try credentials.save(user: "alex", password: "устаревший", for: server)

        let outcome = await connection.connect(to: server)

        #expect(outcome == .needsCredentials(suggestedUser: "alex", reason: .savedPasswordRejected))
    }

    @Test("недоступный сервер не выглядит как неверный пароль")
    func networkErrorIsNotAuthError() async throws {
        let (connection, _, credentials, _) = makeConnection(.failure(Int32(EHOSTUNREACH)))
        try credentials.save(user: "alex", password: "секрет", for: server)

        let outcome = await connection.connect(to: server)

        guard case .failed(let message) = outcome else {
            Issue.record("ожидалась ошибка сети, получено \(outcome)")
            return
        }
        #expect(message.contains("недоступен"))
    }

    // MARK: - Скрытые ресурсы

    @Test("«нет такого ресурса» гостем ведёт на экран входа, а не в тупик")
    func hiddenShareAsksForCredentials() async {
        // Samba прячет запароленную шару от гостя: отвечает ENOENT вместо отказа
        // в доступе. Без этого пользователь видел «проверьте имя объекта»
        // на папке, которая существует и просто требует пароль.
        let (connection, _, _, _) = makeConnection(.failure(Int32(ENOENT)))

        let outcome = await connection.connect(to: server)

        #expect(outcome == .needsCredentials(suggestedUser: nil, reason: .shareHiddenFromGuest))
    }

    @Test("«нет такого ресурса» с введённым паролем остаётся ошибкой")
    func hiddenShareWithCredentialsIsError() async {
        // Логин уже вводили и он не помог — значит папки действительно нет,
        // и предлагать ввести пароль снова было бы издевательством.
        let (connection, _, _, _) = makeConnection(.failure(Int32(ENOENT)))

        let outcome = await connection.connect(to: server, user: "alex", password: "секрет")

        guard case .failed(let message) = outcome else {
            Issue.record("ожидалась ошибка, получено \(outcome)")
            return
        }
        #expect(message.contains("нет"))
    }

    @Test("подсказка про скрытый ресурс называет папку")
    func hiddenSharePromptMentionsShare() {
        let reason = CredentialPrompt.shareHiddenFromGuest

        #expect(reason.message?.contains("вход") == true)
    }

    // MARK: - Сохранение

    @Test("вход с галочкой «Запомнить» кладёт данные в хранилище")
    func savesCredentialsWhenAsked() async {
        let (connection, _, credentials, _) = makeConnection(.mounted(URL(fileURLWithPath: "/Volumes/Общие")))

        _ = await connection.connect(to: server, user: "alex", password: "секрет", remember: true)

        #expect(credentials.load(for: server)?.password == "секрет")
    }

    @Test("без галочки «Запомнить» пароль не сохраняется")
    func doesNotSaveWhenNotAsked() async {
        let (connection, _, credentials, _) = makeConnection(.mounted(URL(fileURLWithPath: "/Volumes/Общие")))

        _ = await connection.connect(to: server, user: "alex", password: "секрет", remember: false)

        #expect(credentials.load(for: server) == nil)
    }

    @Test("гостевой вход не создаёт записи в хранилище")
    func guestSavesNothing() async {
        let (connection, _, credentials, _) = makeConnection(.mounted(URL(fileURLWithPath: "/Volumes/pub")))

        _ = await connection.connect(to: server, asGuest: true, remember: true)

        #expect(credentials.load(for: server) == nil)
    }

    @Test("неудачный вход не сохраняет неверный пароль")
    func failedLoginSavesNothing() async {
        let (connection, _, credentials, _) = makeConnection(.failure(Int32(EAUTH)))

        _ = await connection.connect(to: server, user: "alex", password: "неверный", remember: true)

        #expect(credentials.load(for: server) == nil)
    }

    @Test("гостевой вход помечает закладку, чтобы в следующий раз не спрашивать")
    func guestLoginMarksBookmark() async {
        let (connection, _, _, bookmarks) = makeConnection(.mounted(URL(fileURLWithPath: "/Volumes/pub")))

        _ = await connection.connect(to: server, asGuest: true, remember: false)

        #expect(bookmarks.items.first?.isGuest == true)
    }

    // MARK: - Состояние подключения

    @Test("успешное подключение отмечает сервер как смонтированный")
    func marksServerMounted() async {
        let point = URL(fileURLWithPath: "/Volumes/Общие")
        let (connection, _, _, _) = makeConnection(.mounted(point))

        _ = await connection.connect(to: server)

        #expect(connection.mounted.isMounted(server))
        #expect(connection.mounted.mountPoint(for: server)?.path == point.path)
    }

    @Test("отключение размонтирует том и забывает его")
    func disconnectUnmounts() async {
        let point = URL(fileURLWithPath: "/Volumes/Общие")
        let (connection, mounter, _, _) = makeConnection(.mounted(point))
        _ = await connection.connect(to: server)

        let error = await connection.disconnect(from: server)

        #expect(error == nil)
        #expect(mounter.unmounted.map(\.path) == [point.path])
        #expect(!connection.mounted.isMounted(server))
    }

    @Test("занятый том остаётся подключённым, а ошибка доходит до пользователя")
    func busyVolumeStaysMounted() async {
        let (connection, mounter, _, _) = makeConnection(.mounted(URL(fileURLWithPath: "/Volumes/Общие")))
        _ = await connection.connect(to: server)
        mounter.unmountError = MountError(code: Int32(EBUSY), host: server.host)

        let error = await connection.disconnect(from: server)

        #expect(error != nil)
        #expect(connection.mounted.isMounted(server))
    }

    // MARK: - Забыть и удалить

    @Test("«Забыть пароль» стирает данные, но оставляет закладку")
    func forgetPasswordKeepsBookmark() async throws {
        let (connection, _, credentials, bookmarks) = makeConnection(.mounted(URL(fileURLWithPath: "/Volumes/Общие")))
        try credentials.save(user: "alex", password: "секрет", for: server)
        bookmarks.remember(server, isGuest: false)

        connection.forgetPassword(for: server)

        #expect(credentials.load(for: server) == nil)
        #expect(bookmarks.items.count == 1)
    }

    @Test("удаление закладки стирает и пароль")
    func removingBookmarkDeletesPassword() throws {
        let (connection, _, credentials, bookmarks) = makeConnection(.mounted(URL(fileURLWithPath: "/Volumes/Общие")))
        try credentials.save(user: "alex", password: "секрет", for: server)
        bookmarks.remember(server, isGuest: false)

        connection.removeBookmark(for: server)

        #expect(bookmarks.items.isEmpty)
        #expect(credentials.load(for: server) == nil)
    }

    @Test("сохранённый логин виден форме редактирования")
    func exposesSavedUser() throws {
        let (connection, _, credentials, _) = makeConnection(.needsAuth)
        try credentials.save(user: "alex", password: "секрет", for: server)

        #expect(connection.savedUser(for: server) == "alex")
        #expect(connection.hasSavedPassword(for: server))
    }

    @Test("проверка наличия пароля не читает сам пароль")
    func checkingPasswordPresenceDoesNotReadIt() throws {
        let (connection, _, credentials, _) = makeConnection(.needsAuth)
        try credentials.save(user: "alex", password: "секрет", for: server)
        credentials.resetCounters()

        #expect(connection.hasSavedPassword(for: server))

        // Чтение данных пароля — это то, что вызывает диалог Связки ключей.
        // Для ответа «пароль есть» оно не нужно: хватает проверки существования записи.
        #expect(credentials.loadCount == 0)
        #expect(credentials.existsCount == 1)
    }

    @Test("пустой пароль при сохранении настроек не затирает сохранённый")
    func emptyPasswordKeepsStoredOne() throws {
        let (connection, _, credentials, _) = makeConnection(.needsAuth)
        try credentials.save(user: "alex", password: "секрет", for: server)

        connection.updateSettings(for: server, user: "boris", password: "", isGuest: false)

        #expect(credentials.load(for: server)?.user == "boris")
        #expect(credentials.load(for: server)?.password == "секрет")
    }

    @Test("новый пароль в настройках заменяет сохранённый")
    func newPasswordReplacesStoredOne() throws {
        let (connection, _, credentials, _) = makeConnection(.needsAuth)
        try credentials.save(user: "alex", password: "старый", for: server)

        connection.updateSettings(for: server, user: "alex", password: "новый", isGuest: false)

        #expect(credentials.load(for: server)?.password == "новый")
    }

    @Test("закладки, сохранённые до появления флага гостя, читаются")
    func decodesLegacyBookmarks() throws {
        let defaults = UserDefaults(suiteName: "tests.legacy.\(UUID().uuidString)")!
        // Формат старой версии: поля isGuest в JSON ещё не было.
        let legacy = #"[{"address":"smb://nas.local/Share","name":"Share (nas.local)"}]"#
        defaults.set(Data(legacy.utf8), forKey: "servers.bookmarks")

        let bookmarks = ServerBookmarks(defaults: defaults)

        #expect(bookmarks.items.count == 1)
        #expect(bookmarks.items.first?.isGuest == false)
        #expect(bookmarks.items.first?.server?.host == "nas.local")
    }

    @Test("отмена пользователем читается как отмена, а не как «ошибка -128»")
    func userCancelReadsAsCancellation() {
        // -128 — userCanceledErr из Carbon: так NetFS сообщает о закрытии
        // своего диалога. Без этой ветки пользователь видел загадочное
        // «Не удалось подключиться (ошибка -128)».
        let error = MountError(code: -128, host: "31.31.196.75")

        #expect(error.message == "Подключение отменено.")
    }

    @Test("переключение закладки на гостя стирает учётные данные")
    func switchingToGuestClearsCredentials() throws {
        let (connection, _, credentials, bookmarks) = makeConnection(.needsAuth)
        try credentials.save(user: "alex", password: "секрет", for: server)
        bookmarks.remember(server, isGuest: false)

        connection.updateSettings(for: server, user: "", password: "", isGuest: true)

        #expect(credentials.load(for: server) == nil)
        #expect(bookmarks.items.first?.isGuest == true)
    }
}
