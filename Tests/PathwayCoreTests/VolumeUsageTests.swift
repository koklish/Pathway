import Foundation
import Testing

@testable import PathwayCore

@Suite("Занятость тома")
struct VolumeUsageTests {
    private func usage(total: Int64, available: Int64, isNetwork: Bool = false) -> VolumeUsage {
        VolumeUsage(
            url: URL(fileURLWithPath: "/Volumes/Тест"),
            name: "Тест",
            isNetwork: isNetwork,
            totalBytes: total,
            availableBytes: available
        )
    }

    private let gigabyte: Int64 = 1_000_000_000

    @Test("доля занятого считается от общего объёма")
    func computesFraction() {
        let volume = usage(total: 294 * gigabyte, available: 79 * gigabyte)

        #expect(abs(volume.fraction - 0.731) < 0.001)
        #expect(volume.usedBytes == 215 * gigabyte)
    }

    @Test("нулевой объём тома даёт долю 0, а не NaN")
    func zeroCapacityGivesZeroFraction() {
        // FTP-том отдаёт нули, а NaN в ширине полоски роняет отрисовку целиком.
        let volume = usage(total: 0, available: 0)

        #expect(volume.fraction == 0)
        #expect(!volume.fraction.isNaN)
    }

    @Test("свободного больше общего — занятое ноль, а не отрицательное")
    func clampsNegativeUsed() {
        // Сетевой сервер волен вернуть несогласованные числа; отрицательная
        // ширина полоски — крэш отрисовки, а не кривая картинка.
        let volume = usage(total: 10 * gigabyte, available: 20 * gigabyte)

        #expect(volume.usedBytes == 0)
        #expect(volume.fraction == 0)
    }

    @Test("доля не превышает единицы даже при странных числах сервера")
    func clampsFractionToOne() {
        let volume = VolumeUsage(
            url: URL(fileURLWithPath: "/Volumes/Тест"),
            name: "Тест",
            isNetwork: true,
            totalBytes: 10 * gigabyte,
            availableBytes: -5 * gigabyte
        )

        #expect(volume.fraction == 1)
    }

    @Test("подпись называет и свободное, и общее")
    func captionNamesFreeAndTotal() {
        let caption = usage(total: 294 * gigabyte, available: 79 * gigabyte).caption

        #expect(caption.contains("79"))
        #expect(caption.contains("294"))
    }

    @Test("объём пишется русскими единицами, а не GB латиницей")
    func sizeUsesRussianUnits() {
        // ByteCountFormatter пишет «315,92 GB» независимо от локали приложения
        // и «Zero KB» на нуле — в русском интерфейсе это чужой текст.
        #expect(VolumeUsage.size(315_920_000_000) == "316 ГБ")
        #expect(VolumeUsage.size(0) == "0 Б")
        #expect(VolumeUsage.size(84_820_000_000) == "84,8 ГБ")
    }

    @Test("байты пишутся целыми, а не с запятой")
    func bytesAreWhole() {
        #expect(VolumeUsage.size(512) == "512 Б")
    }

    @Test("объём от сотни единиц округляется до целых")
    func largeValuesDropFraction() {
        // «1024,3 ГБ» — уже шум: на таком масштабе десятые ничего не решают.
        #expect(VolumeUsage.size(1_024_300_000_000) == "1,0 ТБ")
        #expect(VolumeUsage.size(150_000_000_000) == "150 ГБ")
    }

    @Test("имя тома показывается без логина")
    func stripsCredentialsFromName() {
        // FTP-том macOS называет «u3371448@31.31.196.75»; логин в сайдбаре не
        // нужен никому, а на чужом экране ещё и лишний.
        #expect(VolumeUsageReader.displayName("u3371448@31.31.196.75") == "31.31.196.75")
        #expect(VolumeUsageReader.displayName("Спецификации") == "Спецификации")
    }

    @Test("имя, оканчивающееся на @, остаётся как есть")
    func keepsTrailingAt() {
        // Иначе от такого имени осталась бы пустая строка — строка сайдбара без
        // названия вовсе.
        #expect(VolumeUsageReader.displayName("Диск@") == "Диск@")
    }

    @Test("почти заполненным том считается выше 90 %, а не на 90 %")
    func nearlyFullThreshold() {
        // Ровно на пороге — ещё не тревога: иначе полоска краснела бы у тома,
        // на котором свободна десятая часть, и красный перестал бы что-то значить.
        #expect(!usage(total: 100 * gigabyte, available: 10 * gigabyte).isNearlyFull)
        #expect(usage(total: 100 * gigabyte, available: 5 * gigabyte).isNearlyFull)
    }
}

@Suite("Список дисков")
@MainActor
struct VolumesModelTests {
    /// Читатель томов, отдающий заготовленный ответ вместо опроса системы.
    private final class InMemoryReader: VolumeUsageReading, @unchecked Sendable {
        var response: [VolumeUsage]
        private(set) var readCount = 0

        init(_ response: [VolumeUsage]) { self.response = response }

        func read() -> [VolumeUsage] {
            readCount += 1
            return response
        }
    }

    private func volume(_ name: String) -> VolumeUsage {
        VolumeUsage(
            url: URL(fileURLWithPath: "/Volumes/\(name)"),
            name: name,
            isNetwork: false,
            totalBytes: 100,
            availableBytes: 50
        )
    }

    @Test("refresh заполняет список тем, что отдал читатель")
    func refreshFillsVolumes() {
        let reader = InMemoryReader([volume("MAIN")])
        let model = VolumesModel(reader: reader)

        model.refresh()

        #expect(model.volumes.map(\.name) == ["MAIN"])
        #expect(reader.readCount == 1)
    }

    @Test("повторный refresh заменяет список, а не добавляет к нему")
    func refreshReplacesList() {
        let reader = InMemoryReader([volume("MAIN")])
        let model = VolumesModel(reader: reader)
        model.refresh()

        reader.response = [volume("Спецификации")]
        model.refresh()

        #expect(model.volumes.map(\.name) == ["Спецификации"])
    }

    @Test("отключённый том исчезает из списка, а не остаётся от прошлого чтения")
    func removedVolumeDisappears() {
        // Том могли отключить в Finder или выдернув сеть; оставшаяся строка
        // вела бы в никуда.
        let reader = InMemoryReader([volume("MAIN")])
        let model = VolumesModel(reader: reader)
        model.refresh()

        reader.response = []
        model.refresh()

        #expect(model.volumes.isEmpty)
    }
}
