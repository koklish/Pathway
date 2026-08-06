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

    /// Учётная запись, под которой смонтирован том в этой точке.
    ///
    /// Нужна секции «Диски»: `VolumeUsage` читается через `statfs` и о сервере не
    /// знает ничего, а логин у ресурса, открытого дважды, — единственное, чем
    /// строки различаются на вид.
    ///
    /// Сопоставление по точке монтирования, а не по имени тома: у одного ресурса,
    /// подключённого под двумя учётными записями, имена совпадают («MAIN» и
    /// «MAIN»), а точки монтирования уникальны — их выдаёт система.
    public func user(at mountPoint: URL) -> String? {
        networkVolumes.first { $0.mountPoint.path == mountPoint.path }?.server.user
    }

    /// Сверяет учтённые тома с файловой системой.
    ///
    /// Том могли отключить мимо нас — через Finder или выдернув сеть. Проверяем
    /// существование точки монтирования и забываем то, чего больше нет.
    public func refresh() {
        points = points.filter { FileManager.default.fileExists(atPath: $0.value.path) }
        adoptExistingMounts()
    }

    /// Все учтённые тома: адрес сервера и точка монтирования.
    ///
    /// Нужен переподключению после сна — оно обходит именно учтённые тома, а не
    /// networkVolumes: там лежит то, что видно системе, и залипший том попадает
    /// в оба списка, а вот забытый нами — только в первый.
    public var entries: [(server: ServerAddress, mountPoint: URL)] {
        networkVolumes.map { ($0.server, $0.mountPoint) }
    }

    /// Отвечает ли том за отведённое время.
    ///
    /// fileExists здесь не годится: отвалившийся после сна SMB-том остаётся в
    /// таблице монтирования, и проверка существования возвращает true — именно
    /// поэтому приложение считало такой том живым и не пыталось переподключиться.
    ///
    /// Обращение к нему при этом не даёт ошибки, а виснет до системного
    /// таймаута в десятки секунд, поэтому проверка уведена с главного потока и
    /// ограничена своим сроком. Живой том в локальной сети отвечает за единицы
    /// миллисекунд; двух секунд хватает пережить кратковременную загрузку сети,
    /// не заставляя человека ждать.
    public static func responds(at mountPoint: URL, timeout: Duration = .seconds(2)) async -> Bool {
        let path = mountPoint.path

        return await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask(priority: .userInitiated) {
                var info = statfs()
                return statfs(path, &info) == 0
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }

            // Первый ответивший и есть результат: сбоку от группы держать
            // задачи нельзя — cancelAll до них не дотянется, и ожидание их
            // value связало бы нас на весь срок таймаута даже при мгновенном
            // ответе statfs.
            let first = await group.next() ?? false
            // Отменяем оставшуюся: таймер этим снимается сразу, а зависшая
            // statfs отмены не увидит — она в ядре, — но группа её больше не
            // ждёт, и вызывающий получает ответ вовремя.
            group.cancelAll()
            return first
        }
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
