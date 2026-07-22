import AppKit
import Foundation
import NetFS

/// Чем закончилась попытка подключения.
public enum MountResult: Equatable, Sendable {
    /// Том смонтирован, вот его точка монтирования в /Volumes.
    case mounted(URL)
    /// Сервер требует логин и пароль — нужно показать экран авторизации.
    case authenticationRequired
}

/// Ошибка подключения с текстом, который не стыдно показать пользователю.
public struct MountError: LocalizedError, Equatable {
    public let message: String
    public let code: Int32

    public var errorDescription: String? { message }

    public init(code: Int32, host: String) {
        self.code = code
        self.message = Self.describe(code: code, host: host)
    }

    /// Тип сервера не определился: ни один из известных портов не отвечает.
    public init(unknownProtocolAt host: String) {
        self.code = Int32(EPROTONOSUPPORT)
        self.message = """
            Не удалось определить тип сервера «\(host)». \
            Проверьте адрес или укажите протокол явно — например, «ftp://\(host)».
            """
    }

    /// Не удалось отключить том. Чаще всего причина одна — на нём открыты файлы.
    public init(busyVolumeAt mountPoint: URL) {
        self.code = Int32(EBUSY)
        let name = mountPoint.lastPathComponent
        self.message = """
            Не удалось отключить «\(name)»: том занят. \
            Закройте открытые с него файлы и программы, затем попробуйте снова.
            """
    }

    private static func describe(code: Int32, host: String) -> String {
        switch code {
        case Int32(EAUTH), Int32(EACCES), Int32(EPERM):
            return "Не удалось войти на «\(host)». Проверьте имя пользователя и пароль."
        case Int32(ENOENT):
            return "Сервер «\(host)» доступен, но такого ресурса на нём нет. Проверьте адрес."
        case Int32(EHOSTUNREACH), Int32(EHOSTDOWN), Int32(ENETDOWN), Int32(ENETUNREACH):
            return "Сервер «\(host)» недоступен. Проверьте адрес и подключение к сети."
        case Int32(ETIMEDOUT):
            return "Сервер «\(host)» не ответил вовремя. Возможно, он выключен или закрыт файрволом."
        case Int32(ECONNREFUSED):
            return "Сервер «\(host)» отклонил подключение. Проверьте, что нужная служба на нём включена."
        case Int32(ECANCELED):
            return "Подключение отменено."
        default:
            return "Не удалось подключиться к «\(host)» (ошибка \(code))."
        }
    }
}

/// Умеет подключать и отключать сетевой том. Отдельный протокол — чтобы тесты не ходили в сеть.
public protocol Mounting: Sendable {
    func mount(
        _ server: ServerAddress,
        user: String?,
        password: String?,
        guest: Bool
    ) throws -> MountResult

    func unmount(_ mountPoint: URL) throws
}

/// Подключает сетевые диски через NetFS.
public struct ServerMounter: Mounting, Sendable {
    public init() {}

    /// Монтирует том. Без учётных данных сначала пробует гостевой вход;
    /// если сервер требует авторизацию, возвращает `.authenticationRequired`.
    ///
    /// Вызов блокирующий — выполнять вне главного потока.
    public func mount(
        _ server: ServerAddress,
        user: String? = nil,
        password: String? = nil,
        guest: Bool = false
    ) throws -> MountResult {
        // Схема к этому моменту обязана быть определена: ConnectServerModel
        // либо берёт её из адреса, либо выясняет пробой портов.
        guard let url = server.url else {
            throw MountError(unknownProtocolAt: server.host)
        }

        let openOptions = NSMutableDictionary()
        if guest {
            openOptions[kNetFSUseGuestKey as String] = true
        } else if user != nil {
            // Учётные данные храним сами, в своей записи Связки ключей, поэтому
            // системные предпочтения NetFS здесь не трогаем.
            openOptions[kNetFSAllowLoopbackKey as String] = true
        } else {
            // Первая попытка: без диалогов, чтобы самим показать свой экран авторизации.
            openOptions[kNetFSUseGuestKey as String] = true
        }

        var mountpoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(
            url as CFURL,
            nil,
            user as CFString?,
            password as CFString?,
            openOptions as CFMutableDictionary,
            nil,
            &mountpoints
        )

        guard status == 0 else {
            // Гостевой вход не прошёл по правам — значит сервер ждёт учётные данные.
            let needsAuth = status == Int32(EAUTH) || status == Int32(EACCES) || status == Int32(EPERM)
            if needsAuth, user == nil, !guest {
                return .authenticationRequired
            }
            throw MountError(code: status, host: server.host)
        }

        let paths = mountpoints?.takeRetainedValue() as? [String] ?? []
        guard let first = paths.first else {
            throw MountError(code: Int32(ENOENT), host: server.host)
        }
        return .mounted(URL(fileURLWithPath: first))
    }

    /// Отключает том. Если на нём открыты файлы, система откажет — и это нормальный
    /// исход, о котором нужно сказать пользователю, а не проглотить.
    public func unmount(_ mountPoint: URL) throws {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: mountPoint)
        } catch {
            throw MountError(busyVolumeAt: mountPoint)
        }
    }
}
