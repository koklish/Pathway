import Foundation
import Observation

/// Чем закончилась попытка подключиться.
public enum ConnectionOutcome: Equatable, Sendable {
    case mounted(URL)
    case needsCredentials(suggestedUser: String?, reason: CredentialPrompt)
    case failed(String)
}

/// Почему у пользователя спрашивают логин и пароль.
public enum CredentialPrompt: Equatable, Sendable {
    /// Подключаемся впервые, сохранённых данных нет.
    case firstTime
    /// Сохранённый пароль сервер не принял.
    case savedPasswordRejected
    /// Сервер ответил «нет такого ресурса» на гостевой вход.
    case shareHiddenFromGuest

    public var message: String? {
        switch self {
        case .firstTime:
            nil
        case .savedPasswordRejected:
            "Не удалось войти с сохранённым паролем. Введите его заново."
        case .shareHiddenFromGuest:
            "Сервер не подтвердил доступ к этой папке. Возможно, нужен вход с именем пользователя."
        }
    }
}

/// Подключение к серверам: учётные данные, монтирование, состояние.
///
/// Собирает вместе закладки, Связку ключей и NetFS, чтобы интерфейсу
/// доставался один понятный ответ: смонтировано, нужен пароль или ошибка.
@Observable
@MainActor
public final class ServerConnection {
    public let bookmarks: ServerBookmarks
    public let mounted: MountedServers

    private let credentials: any CredentialStoring
    private let mounter: any Mounting

    /// Адреса, которые сейчас подключаются, — для индикатора в строке сайдбара.
    public private(set) var connecting: Set<String> = []

    public init(
        bookmarks: ServerBookmarks = ServerBookmarks(),
        credentials: any CredentialStoring = KeychainCredentialStore(),
        mounter: any Mounting = ServerMounter(),
        mounted: MountedServers = MountedServers()
    ) {
        self.bookmarks = bookmarks
        self.credentials = credentials
        self.mounter = mounter
        self.mounted = mounted
    }

    public func isConnecting(_ server: ServerAddress) -> Bool {
        connecting.contains(server.key)
    }

    // MARK: - Подключение

    /// Подключается к серверу.
    ///
    /// Учётные данные выбираются по приоритету: переданные явно → сохранённые
    /// в Связке ключей → гостевой вход, если так помечена закладка. Если ничего
    /// нет, пробуем гостя и по отказу просим авторизацию.
    public func connect(
        to server: ServerAddress,
        user: String? = nil,
        password: String? = nil,
        asGuest: Bool = false,
        remember: Bool = false
    ) async -> ConnectionOutcome {
        let key = server.key
        connecting.insert(key)
        defer { connecting.remove(key) }

        let saved = credentials.load(for: server)
        let wantsGuest = asGuest || (user == nil && saved == nil && bookmarks.bookmark(for: server)?.isGuest == true)

        // Явно переданные данные важнее сохранённых: пользователь только что их ввёл.
        let effectiveUser = asGuest ? nil : (user ?? saved?.user)
        let effectivePassword = asGuest ? nil : (password ?? saved?.password)
        // Пароль сохранённый, а не введённый — значит его отклонение означает «устарел».
        let usedSavedPassword = !asGuest && password == nil && saved != nil

        let mounter = self.mounter
        do {
            let result = try await Task.detached {
                try mounter.mount(server, user: effectiveUser, password: effectivePassword, guest: wantsGuest)
            }.value

            switch result {
            case .authenticationRequired:
                return .needsCredentials(suggestedUser: saved?.user, reason: .firstTime)
            case .mounted(let point):
                finishSuccessfulMount(
                    server, at: point,
                    user: effectiveUser, password: effectivePassword,
                    asGuest: wantsGuest, remember: remember
                )
                return .mounted(point)
            }
        } catch let error as MountError {
            if Self.isAuthFailure(error.code) {
                // Сохранённый пароль перестал подходить — вернём на экран входа,
                // подставив имя, чтобы не набирать его заново.
                if usedSavedPassword {
                    return .needsCredentials(suggestedUser: saved?.user, reason: .savedPasswordRejected)
                }
                if user == nil, !asGuest {
                    return .needsCredentials(suggestedUser: saved?.user, reason: .firstTime)
                }
            }
            // Samba прячет запароленный ресурс от гостя: отвечает «нет такого»
            // вместо отказа в доступе. Отличить это от настоящей опечатки в адресе
            // нельзя, поэтому предлагаем войти — для пользователя это чаще верно.
            // Если учётные данные уже вводили и они не помогли, папки правда нет.
            if error.code == Int32(ENOENT), user == nil, password == nil, !asGuest {
                return .needsCredentials(suggestedUser: saved?.user, reason: .shareHiddenFromGuest)
            }
            return .failed(error.message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func finishSuccessfulMount(
        _ server: ServerAddress,
        at point: URL,
        user: String?,
        password: String?,
        asGuest: Bool,
        remember: Bool
    ) {
        mounted.remember(server, at: point)
        bookmarks.remember(server, isGuest: asGuest)

        guard remember, !asGuest, let user, let password, !password.isEmpty else { return }
        try? credentials.save(user: user, password: password, for: server)
    }

    private static func isAuthFailure(_ code: Int32) -> Bool {
        code == Int32(EAUTH) || code == Int32(EACCES) || code == Int32(EPERM)
    }

    // MARK: - Отключение

    /// Отключает том. Возвращает текст ошибки, если система отказала.
    public func disconnect(from server: ServerAddress) async -> String? {
        guard let point = mounted.mountPoint(for: server) else { return nil }

        let mounter = self.mounter
        do {
            try await Task.detached { try mounter.unmount(point) }.value
            mounted.forget(server)
            return nil
        } catch let error as MountError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Учётные данные

    public func savedUser(for server: ServerAddress) -> String? {
        credentials.load(for: server)?.user
    }

    public func hasSavedPassword(for server: ServerAddress) -> Bool {
        credentials.exists(for: server)
    }

    /// «Забыть пароль»: стирает учётные данные, закладку оставляет.
    public func forgetPassword(for server: ServerAddress) {
        try? credentials.delete(for: server)
    }

    /// «Удалить из списка»: убирает закладку вместе с паролем — держать
    /// учётные данные от сервера, которого нет в списке, незачем.
    public func removeBookmark(for server: ServerAddress) {
        try? credentials.delete(for: server)
        bookmarks.remove(server)
    }

    /// Сохраняет настройки из формы редактирования.
    ///
    /// Пустой пароль означает «не менять»: форма не показывает сохранённый пароль,
    /// поэтому пустое поле — это «пользователь его не трогал», а не «стереть».
    public func updateSettings(
        for server: ServerAddress,
        user: String,
        password: String,
        isGuest: Bool,
        newAddress: ServerAddress? = nil
    ) {
        let target = newAddress ?? server

        if isGuest {
            // Гостю учётные данные не нужны, а оставлять их — значит подсунуть их
            // при следующем подключении вопреки выбранному способу входа.
            try? credentials.delete(for: server)
            if target != server { try? credentials.delete(for: target) }
        } else if !user.isEmpty {
            let existing = credentials.load(for: server)
            let effectivePassword = password.isEmpty ? (existing?.password ?? "") : password
            if !effectivePassword.isEmpty {
                try? credentials.save(user: user, password: effectivePassword, for: target)
                if target != server { try? credentials.delete(for: server) }
            }
        }

        if let newAddress, newAddress != server {
            bookmarks.replace(server, with: newAddress, isGuest: isGuest)
            // Точка монтирования принадлежит прежнему адресу: том остаётся
            // подключённым до тех пор, пока его не отключат вручную.
            if let point = mounted.mountPoint(for: server) {
                mounted.forget(server)
                mounted.remember(newAddress, at: point)
            }
        } else {
            bookmarks.setGuest(isGuest, for: server)
        }
    }
}
