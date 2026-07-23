import Foundation
import Security

/// Логин и пароль для сетевого сервера.
public struct ServerCredentials: Equatable, Sendable {
    public let user: String
    public let password: String

    public init(user: String, password: String) {
        self.user = user
        self.password = password
    }
}

/// Хранилище учётных данных. Отдельный протокол — чтобы тесты не трогали Связку ключей.
public protocol CredentialStoring: Sendable {
    func save(user: String, password: String, for server: ServerAddress) throws
    func load(for server: ServerAddress) -> ServerCredentials?
    func delete(for server: ServerAddress) throws

    /// Есть ли сохранённая запись — без чтения самого пароля.
    ///
    /// Отдельно от `load`, потому что именно чтение данных пароля заставляет macOS
    /// спрашивать разрешение на доступ к Связке ключей. Там, где нужен лишь факт
    /// наличия записи, платить диалогом незачем.
    func exists(for server: ServerAddress) -> Bool

    /// Сохранённый логин — без чтения пароля.
    ///
    /// Логин лежит в атрибуте записи, а не в её защищённых данных, поэтому
    /// подставить его в форму входа можно, не вызывая диалога.
    func savedUser(for server: ServerAddress) -> String?
}

/// Ошибка Связки ключей с читаемым текстом.
public struct CredentialError: LocalizedError, Equatable {
    public let status: OSStatus
    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String?
        return "Не удалось обратиться к Связке ключей: \(detail ?? "ошибка \(status)")"
    }
}

/// Учётные данные в Связке ключей пользователя.
///
/// Класс `kSecClassInternetPassword` выбран намеренно: такие записи видны в системной
/// «Связке ключей» рядом с записями Finder, и пользователь может удалить их без нас.
public struct KeychainCredentialStore: CredentialStoring {
    public init() {}

    public func save(user: String, password: String, for server: ServerAddress) throws {
        // Пароль мог измениться, а логин — смениться на другого пользователя,
        // поэтому проще удалить прежнюю запись, чем разбирать случаи обновления.
        try delete(for: server)

        var query = Self.query(for: server)
        query[kSecAttrAccount as String] = user
        query[kSecValueData as String] = Data(password.utf8)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialError(status: status) }
    }

    public func load(for server: ServerAddress) -> ServerCredentials? {
        var query = Self.query(for: server)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let found = item as? [String: Any],
              let user = found[kSecAttrAccount as String] as? String,
              let data = found[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8)
        else { return nil }

        return ServerCredentials(user: user, password: password)
    }

    /// Проверяет наличие записи, не запрашивая `kSecReturnData`.
    ///
    /// Без данных пароля Связка ключей отвечает по ACL на чтение атрибутов и
    /// диалог подтверждения не показывает.
    public func exists(for server: ServerAddress) -> Bool {
        var query = Self.query(for: server)
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Читает логин через `kSecReturnAttributes`, без `kSecReturnData`.
    ///
    /// Диалога нет по той же причине, что и в `exists`: Связка отвечает по ACL
    /// на чтение атрибутов, а защищённые данные записи здесь не запрашиваются.
    public func savedUser(for server: ServerAddress) -> String? {
        var query = Self.query(for: server)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let found = item as? [String: Any],
              let user = found[kSecAttrAccount as String] as? String
        else { return nil }

        return user
    }

    public func delete(for server: ServerAddress) throws {
        let status = SecItemDelete(Self.query(for: server) as CFDictionary)
        // Записи не было — это не ошибка, результат тот же: её нет.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError(status: status)
        }
    }

    /// Общая часть запроса: она же определяет, что считается одной записью.
    ///
    /// Различаем серверы по хосту и шаре: на одном хосте могут жить ресурсы
    /// с разными правами доступа.
    private static func query(for server: ServerAddress) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server.host,
            kSecAttrPath as String: server.share,
            kSecAttrProtocol as String: protocolValue(for: server.scheme),
        ]
    }

    private static func protocolValue(for scheme: String?) -> CFString {
        switch scheme {
        case "smb", "cifs": kSecAttrProtocolSMB
        case "afp": kSecAttrProtocolAFP
        case "ftp": kSecAttrProtocolFTP
        case "http": kSecAttrProtocolHTTP
        case "https": kSecAttrProtocolHTTPS
        default: kSecAttrProtocolSMB
        }
    }
}

/// Хранилище в памяти — для тестов и превью.
public final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private var storage: [String: ServerCredentials] = [:]
    private let lock = NSLock()

    /// Счётчики обращений: тесты следят, чтобы пароль не читали там,
    /// где хватает `exists` или `savedUser`.
    public private(set) var loadCount = 0
    public private(set) var existsCount = 0
    public private(set) var savedUserCount = 0

    public init() {}

    public func resetCounters() {
        lock.withLock {
            loadCount = 0
            existsCount = 0
            savedUserCount = 0
        }
    }

    public func save(user: String, password: String, for server: ServerAddress) throws {
        lock.withLock { storage[Self.key(server)] = ServerCredentials(user: user, password: password) }
    }

    public func load(for server: ServerAddress) -> ServerCredentials? {
        lock.withLock {
            loadCount += 1
            return storage[Self.key(server)]
        }
    }

    public func exists(for server: ServerAddress) -> Bool {
        lock.withLock {
            existsCount += 1
            return storage[Self.key(server)] != nil
        }
    }

    public func savedUser(for server: ServerAddress) -> String? {
        lock.withLock {
            savedUserCount += 1
            return storage[Self.key(server)]?.user
        }
    }

    public func delete(for server: ServerAddress) throws {
        _ = lock.withLock { storage.removeValue(forKey: Self.key(server)) }
    }

    private static func key(_ server: ServerAddress) -> String {
        "\(server.scheme)://\(server.host)/\(server.share)"
    }
}
