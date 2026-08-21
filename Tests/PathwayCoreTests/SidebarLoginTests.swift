import Foundation
import Testing

@testable import PathwayCore

/// Вход на сервер, начатый из сайдбара, а не из диалога «Подключение».
@MainActor
@Suite("Вход на сервер из сайдбара")
struct SidebarLoginTests {
    /// Пускает только с паролем — как настоящая запароленная шара.
    final class PasswordOnlyMounter: Mounting, @unchecked Sendable {
        let point: URL
        private(set) var mountCalls: [(user: String?, password: String?, guest: Bool)] = []

        init(point: URL) { self.point = point }

        func mount(_ server: ServerAddress, user: String?, password: String?, guest: Bool) throws -> MountResult {
            mountCalls.append((user, password, guest))
            guard let password, !password.isEmpty, user != nil, !guest else {
                return .authenticationRequired
            }
            return .mounted(point)
        }

        func unmount(_ mountPoint: URL) throws {}
        func forceUnmount(_ mountPoint: URL) throws {}
    }

    @Test("после ввода пароля в форме, открытой из сайдбара, сервер монтируется")
    func editingFormActuallyConnects() async {
        let defaults = UserDefaults(suiteName: "tests.sidebar.\(UUID().uuidString)")!
        let mounter = PasswordOnlyMounter(point: URL(fileURLWithPath: "/Volumes/Спецификации"))
        let bookmarks = ServerBookmarks(defaults: defaults)
        let connection = ServerConnection(
            bookmarks: bookmarks,
            credentials: InMemoryCredentialStore(),
            mounter: mounter,
            mounted: MountedServers()
        )
        let model = ConnectServerModel(connection: connection, browser: FakeShareBrowser())

        let server = ServerAddress.parse("smb://i.kogan@samba.ip.pro/Спецификации")!
        bookmarks.remember(server)

        // Шаги 1–2: клик по серверу в сайдбаре. Пароля нет, connect отвечает
        // needsCredentials — сайдбар открывает диалог, как в NetworkSection.
        let outcome = await connection.connect(to: server)
        #expect(outcome == .needsCredentials(suggestedUser: nil, reason: .firstTime))
        model.startAuthenticating(server)

        // Шаги 3–4: пользователь вводит пароль и жмёт кнопку. Окно закрывается.
        model.login = .registered
        model.username = "i.kogan"
        model.password = "secret"
        await model.submit()

        // Шаги 5–6: том обязан быть смонтирован — иначе сервер остался
        // отключённым, и следующий клик снова попросит пароль.
        #expect(connection.mounted.isMounted(server) == true)
    }

    @Test("форма входа предлагает подключиться, а не сохранить настройки")
    func authenticationFormSubmitsAsConnection() {
        let defaults = UserDefaults(suiteName: "tests.sidebar.\(UUID().uuidString)")!
        let connection = ServerConnection(
            bookmarks: ServerBookmarks(defaults: defaults),
            credentials: InMemoryCredentialStore(),
            mounter: RecordingMounter(.needsAuth),
            mounted: MountedServers()
        )
        let model = ConnectServerModel(connection: connection, browser: FakeShareBrowser())
        let server = ServerAddress.parse("smb://i.kogan@samba.ip.pro/Спецификации")!

        model.startAuthenticating(server, reason: .savedPasswordRejected)

        #expect(model.isEditing == false)
        #expect(model.submitTitle == "Подключиться")
        // Логин подставлен из адреса — набирать заново незачем.
        #expect(model.username == "i.kogan")
        // Причина объяснена: иначе повторный запрос пароля выглядит беспричинным.
        #expect(model.noticeMessage == CredentialPrompt.savedPasswordRejected.message)
    }
}
