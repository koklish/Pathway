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
/// Собирает вместе закладки, хранилище учётных данных и NetFS, чтобы интерфейсу
/// доставался один понятный ответ: смонтировано, нужен пароль или ошибка.
@Observable
@MainActor
public final class ServerConnection {
    public let bookmarks: ServerBookmarks
    public let mounted: MountedServers

    private let credentials: any CredentialStoring
    private let mounter: any Mounting
    /// Отвечает ли том в своей точке монтирования.
    ///
    /// Замыкание, а не прямой вызов MountedServers.responds: иначе тест
    /// переподключения полез бы в настоящую файловую систему и зависел бы от
    /// того, что смонтировано на машине в момент прогона. По той же причине,
    /// по которой в проекте протоколами закрыты все остальные границы с ОС.
    private let probe: @Sendable (URL) async -> Bool

    /// Адреса, которые сейчас подключаются, — для индикатора в строке сайдбара.
    public private(set) var connecting: Set<String> = []

    public init(
        bookmarks: ServerBookmarks = ServerBookmarks(),
        credentials: any CredentialStoring = MigratingCredentialStore(
            primary: FileCredentialStore(),
            legacy: KeychainCredentialStore()
        ),
        mounter: any Mounting = ServerMounter(),
        mounted: MountedServers = MountedServers(),
        probe: @escaping @Sendable (URL) async -> Bool = { await MountedServers.responds(at: $0) }
    ) {
        self.bookmarks = bookmarks
        self.credentials = credentials
        self.mounter = mounter
        self.mounted = mounted
        self.probe = probe
    }

    public func isConnecting(_ server: ServerAddress) -> Bool {
        connecting.contains(server.key)
    }

    // MARK: - Подключение

    /// Подключается к серверу.
    ///
    /// Учётные данные выбираются по приоритету: переданные явно → сохранённые →
    /// гостевой вход, если так помечена закладка. Если ничего нет, пробуем гостя
    /// и по отказу просим авторизацию.
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

        // Сохранённый пароль читаем только когда он действительно понадобится.
        // Гостевому входу он не нужен вовсе, а при явно введённых логине и пароле —
        // тем более: пользователь только что набрал их сам. Для записей, ещё не
        // перенесённых из Связки ключей, эта бережливость решает и вторую задачу:
        // именно чтение данных пароля вызывает диалог доступа к Связке.
        // Пароль лежит под адресом с логином — под ним же он и сохранён. Запись,
        // сделанную до того, как логин стал частью адреса, ищем по адресу без
        // логина, но только когда своей записи нет: наличие проверяется через
        // exists, а не вторым load, потому что диалог доступа к Связке ключей
        // вызывает именно чтение данных пароля.
        let legacy = server.user != nil && !credentials.exists(for: server)
        let source = legacy ? server.with(user: nil) : server
        let saved = (asGuest || (user != nil && password != nil))
            ? nil
            : credentials.load(for: source)
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
                // Логин вписывается в адрес до записи в хранилища: именно адрес
                // служит ключом закладок, паролей и точек монтирования, и без
                // него подключение вторым пользователем вытеснило бы первое.
                // Гостю логин не приписываем — у него его нет по определению.
                let identity = wantsGuest ? server : server.with(user: effectiveUser ?? server.user)
                finishSuccessfulMount(
                    identity, at: point,
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

    // MARK: - Переподключение после сна

    /// Снимает отвалившиеся тома и монтирует их заново.
    ///
    /// Сон рвёт SMB-соединение, но том остаётся в таблице монтирования: система
    /// считает его существующим, приложение — подключённым, а любое обращение к
    /// нему виснет до системного таймаута. Отсюда жалоба «после сна обратно уже
    /// не подключается»: переподключаться было некому, ведь по всем признакам
    /// том на месте.
    ///
    /// Залипший том снимается принудительно **в любом случае** — даже когда
    /// заново смонтировать его заведомо не выйдет. Оставленный, он продолжит
    /// вешать приложение при каждом обращении, а это и есть то, на что жалуются.
    ///
    /// Неудача переподключения проходит молча: ноутбук, открытый дома без VPN,
    /// иначе встречал бы человека алертом каждое утро, хотя ничего не сломано —
    /// сервер просто недоступен. Сервер остаётся в сайдбаре отключённым, и клик
    /// по нему запускает обычное подключение со всеми диалогами.
    public func reconnectStaleVolumes() async {
        // Список снимаем до первого await: за время проверок он изменится —
        // forget по ходу дела правит ровно то, по чему мы идём.
        let entries = mounted.entries

        for entry in entries {
            guard await probe(entry.mountPoint) == false else { continue }

            let mounter = self.mounter
            let point = entry.mountPoint
            // Ошибку глотаем: том мог сняться сам, пока мы к нему шли, и
            // «не удалось отключить то, чего нет» — не повод бросать
            // переподключение.
            try? await Task.detached { try mounter.forceUnmount(point) }.value
            mounted.forget(entry.server)

            // Через connect, а не своим путём: выбор учётных данных — сохранённый
            // пароль, гостевой вход, перенос старой записи Связки — там уже
            // разобран, и второй его экземпляр разошёлся бы с первым.
            _ = await connect(to: entry.server)
        }
    }

    // MARK: - Учётные данные

    public func savedUser(for server: ServerAddress) -> String? {
        credentials.savedUser(for: server)
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

    /// То же для конкретной записи списка.
    ///
    /// Отдельный метод, а не разбор адреса на месте: на одном адресе живут разные
    /// учётные записи и гостевой вход, и удаление по адресу унесло бы соседей
    /// вместе с их паролями. Пароль стирается по адресу самой записи — у гостя
    /// его нет, и удалять там нечего.
    public func removeBookmark(_ bookmark: ServerBookmark) {
        if let server = bookmark.server, !bookmark.isGuest {
            try? credentials.delete(for: server)
        }
        bookmarks.remove(bookmark)
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
        // Логин вписывается в целевой адрес: поле адреса в форме его не
        // показывает, и без этого смена учётной записи сохранила бы пароль под
        // прежним ключом, а закладка осталась бы с прежним логином.
        //
        // Только когда логин в адресе уже был: запись, сохранённая до того, как
        // логин стал частью адреса, обязана остаться на своём ключе. Иначе любое
        // открытие её настроек выглядело бы переездом на новый адрес — со
        // сменой ключа пароля и лишней закладкой вместо прежней.
        let base = newAddress ?? server
        let target: ServerAddress
        if isGuest {
            // Гостю логин не приписываем — у него его нет по определению.
            target = base.with(user: nil)
        } else if server.user != nil {
            target = base.with(user: user.isEmpty ? nil : user)
        } else {
            target = base
        }

        if isGuest {
            // Гостю учётные данные не нужны, а оставлять их — значит подсунуть их
            // при следующем подключении вопреки выбранному способу входа.
            try? credentials.delete(for: server)
            if target != server { try? credentials.delete(for: target) }
        } else if !user.isEmpty {
            if !password.isEmpty {
                // Пароль ввели заново — сохранённый читать незачем, он всё равно заменяется.
                try? credentials.save(user: user, password: password, for: target)
                if target != server { try? credentials.delete(for: server) }
            } else if target != server || user != credentials.savedUser(for: server) {
                // Пароль не трогали, но запись надо перенести на новый адрес или сменить
                // в ней логин — только здесь и приходится прочитать сохранённый пароль.
                if let existing = credentials.load(for: server), !existing.password.isEmpty {
                    try? credentials.save(user: user, password: existing.password, for: target)
                    if target != server { try? credentials.delete(for: server) }
                }
            }
            // Иначе адрес и логин прежние, а пароль не меняли: запись уже верна,
            // перезаписывать её тем же значением — лишний диалог Связки ключей.
        }

        // Сравнение с target, а не с newAddress: логин теперь часть адреса, и
        // смена одной только учётной записи при прежнем хосте — это тоже новый
        // адрес записи. По прежнему условию она ушла бы в setGuest и осталась
        // бы с логином, который пользователь только что заменил.
        if target != server {
            bookmarks.replace(server, with: target, isGuest: isGuest)
            // Точка монтирования принадлежит прежнему адресу: том остаётся
            // подключённым до тех пор, пока его не отключат вручную.
            if let point = mounted.mountPoint(for: server) {
                mounted.forget(server)
                mounted.remember(target, at: point)
            }
        } else {
            bookmarks.setGuest(isGuest, for: server)
        }
    }
}
