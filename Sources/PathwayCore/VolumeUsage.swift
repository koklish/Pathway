import Foundation
import Observation

/// Занятость одного смонтированного тома.
public struct VolumeUsage: Identifiable, Equatable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let isNetwork: Bool
    public let totalBytes: Int64
    public let availableBytes: Int64

    public init(url: URL, name: String, isNetwork: Bool, totalBytes: Int64, availableBytes: Int64) {
        self.url = url
        self.name = name
        self.isNetwork = isNetwork
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    /// Занято байт. Считается вычитанием, а не берётся у системы напрямую: на
    /// APFS загрузочный том разложен по контейнерам с общим пулом, и «/» отдаёт
    /// занято 13 ГБ там, где израсходовано 273 — остальное лежит в
    /// /System/Volumes/Data. Свободное место у контейнеров общее и честное.
    ///
    /// Отрицательное схлопывается в ноль: сетевой сервер волен вернуть
    /// свободного больше общего, а отрицательная ширина полоски — крэш
    /// отрисовки, а не кривая картинка.
    public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

    /// Доля занятого, 0…1. Ноль при нулевом объёме: FTP-том отдаёт нули, и
    /// деление дало бы NaN, роняющий отрисовку полоски целиком.
    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(totalBytes))
    }

    /// Место кончается. Порог живёт здесь, а не во вью: это правило, а не
    /// оформление. Строгое сравнение — ровно на пороге ещё не тревога, иначе
    /// краснел бы том со свободной десятой частью, и красный перестал бы
    /// что-то значить.
    public var isNearlyFull: Bool { fraction > 0.9 }

    /// Подпись под полоской — «Свободно 84,9 ГБ из 315,9 ГБ».
    public var caption: String {
        "Свободно \(Self.size(max(0, availableBytes))) из \(Self.size(max(0, totalBytes)))"
    }

    /// Объём по-русски.
    ///
    /// Своё форматирование, а не ByteCountFormatter: тот пишет единицы
    /// латиницей («315,92 GB») независимо от локали приложения и выдаёт
    /// «Zero KB» на нуле — в русском интерфейсе и то, и другое читается как
    /// чужой текст. Десятичные приставки, как у Finder: 1 ГБ = 1000 МБ.
    static func size(_ bytes: Int64) -> String {
        let units: [(limit: Double, suffix: String)] = [
            (1_000, "Б"), (1_000_000, "КБ"), (1_000_000_000, "МБ"),
            (1_000_000_000_000, "ГБ"), (.infinity, "ТБ"),
        ]
        let value = Double(bytes)
        var scale = 1.0
        for unit in units {
            if value < unit.limit {
                // Байты целыми: «0,0 Б» выглядит поломкой формата.
                guard scale > 1 else { return "\(bytes) \(unit.suffix)" }
                let scaled = value / scale
                // Один знак после запятой до сотни, дальше целые: «701,1 ГБ»
                // информативно, «701,09 ГБ» — уже шум.
                let digits = scaled < 100 ? 1 : 0
                return String(format: "%.\(digits)f %@", locale: Locale(identifier: "ru_RU"), scaled, unit.suffix)
            }
            scale = unit.limit
        }
        return "\(bytes) Б"
    }
}

/// Граница с файловой системой: что смонтировано и сколько на нём места.
///
/// Протокол — по общему правилу проекта о границах с ОС: ответ зависит от того,
/// что смонтировано на машине в момент прогона, и без подмены секция
/// проверялась бы только глазами.
public protocol VolumeUsageReading: Sendable {
    func read() -> [VolumeUsage]
}

/// Читает занятость томов у системы.
public struct VolumeUsageReader: VolumeUsageReading {
    public init() {}

    private static let keys: [URLResourceKey] = [
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeNameKey,
        .volumeIsLocalKey,
    ]

    public func read() -> [VolumeUsage] {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Self.keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return volumes.compactMap { url -> VolumeUsage? in
            guard Self.isUserVisible(url) else { return nil }
            guard let values = try? url.resourceValues(forKeys: Set(Self.keys)),
                  let total = values.volumeTotalCapacity,
                  let available = values.volumeAvailableCapacity
            else { return nil }

            // Загрузочный том система называет по имени контейнера, а «/» имени
            // не имеет вовсе — тогда берём то, чем его зовёт Finder.
            let raw = values.volumeName ?? (url.path == "/" ? "Macintosh HD" : url.lastPathComponent)
            return VolumeUsage(
                url: url,
                name: Self.displayName(raw),
                // Неизвестный тип считаем локальным — как в SidebarModel: ошибка
                // в иконке безобиднее пропущенного диска.
                isNetwork: !(values.volumeIsLocal ?? true),
                totalBytes: Int64(total),
                availableBytes: Int64(available)
            )
        }
    }

    /// Имя тома без учётных данных.
    ///
    /// FTP-том macOS называет по адресу вместе с логином —
    /// «u3371448@31.31.196.75». Логин в сайдбаре не нужен никому, а на чужом
    /// экране ещё и лишний.
    static func displayName(_ raw: String) -> String {
        guard let separator = raw.lastIndex(of: "@"), separator < raw.index(before: raw.endIndex) else {
            return raw
        }
        return String(raw[raw.index(after: separator)...])
    }

    /// Том, который пользователь считает диском.
    ///
    /// `df` показывает десяток служебных точек — devfs, /System/Volumes/VM,
    /// Preboot, Update, xarts, — и без отбора секция состояла бы в основном из
    /// них. `.skipHiddenVolumes` снимает часть, но не контейнеры внутри
    /// /System/Volumes: для системы они полноценные тома.
    private static func isUserVisible(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path != "/" else { return true }
        // Строго внутри /Volumes: сам каталог не том, а «/VolumesX» не вложен —
        // отсюда слэш в префиксе, а не просто hasPrefix("/Volumes").
        return path.hasPrefix("/Volumes/")
    }
}

/// Смонтированные тома с их занятостью.
@Observable
@MainActor
public final class VolumesModel {
    public private(set) var volumes: [VolumeUsage] = []

    private let reader: any VolumeUsageReading

    public init(reader: any VolumeUsageReading = VolumeUsageReader()) {
        self.reader = reader
    }

    /// Перечитывает список целиком, а не дополняет его: том могли отключить в
    /// Finder или выдернув сеть, и оставшаяся строка вела бы в никуда.
    ///
    /// Синхронно: под капотом statfs по уже готовой таблице монтирования, счёт
    /// идёт на микросекунды даже для сетевого тома. Обхода каталогов здесь нет,
    /// и Task.detached был бы усложнением без выигрыша.
    public func refresh() {
        volumes = reader.read()
    }
}
