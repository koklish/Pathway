import Foundation
import Observation

/// Какие серверы подключены прямо сейчас и где их точки монтирования.
///
/// Состояние не переживает перезапуск намеренно: том мог отвалиться, пока
/// приложение было закрыто. При старте список пуст и наполняется по мере подключений.
@Observable
@MainActor
public final class MountedServers {
    /// Сетевой том, найденный в системе: где смонтирован и с какого сервера.
    public struct NetworkVolume: Identifiable, Equatable, Sendable {
        public var id: String { mountPoint.path }
        public let server: ServerAddress
        public let mountPoint: URL
        /// Имя тома для сайдбара — «MAIN (samba.ip.pro)».
        public var name: String { server.displayName }
    }

    private var points: [String: URL] = [:]
    /// Тома, найденные в системе, включая смонтированные мимо приложения.
    public private(set) var networkVolumes: [NetworkVolume] = []

    public init() {}

    public func remember(_ server: ServerAddress, at mountPoint: URL) {
        points[Self.key(server)] = mountPoint
    }

    public func forget(_ server: ServerAddress) {
        points.removeValue(forKey: Self.key(server))
    }

    public func isMounted(_ server: ServerAddress) -> Bool {
        mountPoint(for: server) != nil
    }

    public func mountPoint(for server: ServerAddress) -> URL? {
        points[Self.key(server)]
    }

    /// Сверяет учтённые тома с файловой системой.
    ///
    /// Том могли отключить мимо нас — через Finder или выдернув сеть. Проверяем
    /// существование точки монтирования и забываем то, чего больше нет.
    public func refresh() {
        points = points.filter { FileManager.default.fileExists(atPath: $0.value.path) }
        adoptExistingMounts()
    }

    /// Подхватывает сетевые тома, смонтированные мимо приложения.
    ///
    /// Диск могли подключить в Finder или до запуска Pathway. Без этого такой том
    /// исчезал бы из сайдбара совсем: в «Местах» его нет по определению, а в «Сети»
    /// он бы не появился, потому что закладки на него никто не создавал.
    public func adoptExistingMounts() {
        adopt(Self.scanNetworkMounts())
    }

    /// Отделено от чтения системы: так дедупликацию можно проверить на данных,
    /// а не на том, что случайно смонтировано на машине в момент прогона.
    func adopt(_ found: [NetworkVolume]) {
        networkVolumes = Self.deduplicated(found)
        for volume in networkVolumes {
            points[Self.key(volume.server)] = volume.mountPoint
        }
    }

    /// Схлопывает повторные монтирования одного ресурса.
    ///
    /// `/Volumes/MAIN` и `/Volumes/MAIN-1` — один и тот же сервер, подключённый
    /// дважды. В сайдбаре это одна строка: держимся первой точки, остальные
    /// обычно следы прошлых подключений.
    static func deduplicated(_ volumes: [NetworkVolume]) -> [NetworkVolume] {
        var seen: Set<ServerAddress> = []
        return volumes.filter { seen.insert($0.server).inserted }
    }

    /// Читает таблицу монтирования и оставляет сетевые файловые системы.
    private static func scanNetworkMounts() -> [NetworkVolume] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }

        var volumes: [NetworkVolume] = []
        for index in 0..<Int(count) {
            var entry = buffer[index]
            // Сетевой том помечен флагом MNT_LOCAL по отсутствию: локальные диски его несут.
            guard entry.f_flags & UInt32(MNT_LOCAL) == 0 else { continue }

            let mountPoint = withUnsafePointer(to: &entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let source = withUnsafePointer(to: &entry.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }

            // Точки вроде /System/Volumes/Data сюда не относятся — нас интересуют диски.
            guard mountPoint.hasPrefix("/Volumes/"), let server = ServerAddress.parse(source) else { continue }
            volumes.append(NetworkVolume(server: server, mountPoint: URL(fileURLWithPath: mountPoint)))
        }
        return volumes
    }

    private static func key(_ server: ServerAddress) -> String {
        // Через server.key, а не интерполяцией: схема опциональна, и «\(scheme)»
        // подставил бы в ключ строку «Optional("smb")».
        server.key
    }
}
