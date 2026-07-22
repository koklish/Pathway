import Foundation
import Testing

@testable import PathwayCore

/// Замер на реальном сетевом томе. Запускается вручную:
///   swift test --filter SMBBenchmark
/// Без смонтированного тома тест просто пропускается.
private let smbRoot = "/Volumes/MAIN/Project/! ОС 223 !/ФД/Задачи"

@Suite("Замер на SMB", .disabled(if: !FileManager.default.fileExists(atPath: smbRoot)))
struct SMBBenchmark {
    static let root = smbRoot

    @Test("на большой папке быстрый проход обгоняет полную загрузку")
    func fastPathIsFasterOnLargeDirectory() throws {
        let loader = DirectoryLoader()
        let dir = URL(fileURLWithPath: Self.root)

        // Сама папка «Задачи» — 510 подпапок, ради неё всё и делалось.
        let t1 = Date()
        let fast = try loader.loadNames(directory: dir)
        let fastMs = Date().timeIntervalSince(t1) * 1000

        let t2 = Date()
        let full = try loader.load(directory: dir)
        let fullMs = Date().timeIntervalSince(t2) * 1000

        print(String(format: "SMB, %d объектов: полная %.0f мс → быстрая %.0f мс",
                     full.count, fullMs, fastMs))

        #expect(fast.map(\.name) == full.map(\.name))
        #expect(fast.map(\.isDirectory) == full.map(\.isDirectory))
        #expect(fastMs < fullMs)
    }

    @Test("на маленьких папках быстрый проход даёт тот же результат")
    func fastPathMatchesOnSmallDirectories() throws {
        let loader = DirectoryLoader()
        let all = try FileManager.default.contentsOfDirectory(atPath: Self.root).sorted()
        let sample = Array(all.suffix(6))

        // Кто читает папку вторым, тот читает уже прогретую — поэтому чередуем,
        // кто идёт первым, иначе замер льстит одному из вариантов.
        var fastTotal = 0.0, fullTotal = 0.0
        for (index, name) in sample.enumerated() {
            let dir = URL(fileURLWithPath: Self.root).appendingPathComponent(name)
            var fast: [FileItem] = []
            var full: [FileItem] = []

            if index.isMultiple(of: 2) {
                let t1 = Date()
                fast = (try? loader.loadNames(directory: dir)) ?? []
                fastTotal += Date().timeIntervalSince(t1) * 1000
                let t2 = Date()
                full = (try? loader.load(directory: dir)) ?? []
                fullTotal += Date().timeIntervalSince(t2) * 1000
            } else {
                let t2 = Date()
                full = (try? loader.load(directory: dir)) ?? []
                fullTotal += Date().timeIntervalSince(t2) * 1000
                let t1 = Date()
                fast = (try? loader.loadNames(directory: dir)) ?? []
                fastTotal += Date().timeIntervalSince(t1) * 1000
            }

            // Главное: скорость не куплена ценой неверных данных.
            #expect(fast.map(\.name) == full.map(\.name))
            #expect(fast.map(\.isDirectory) == full.map(\.isDirectory))
        }

        // Скорость здесь не проверяем: на папках в 1–7 объектов разница в пределах
        // сетевого шума, а смысл оптимизации — большие каталоги.
        print(String(format: "SMB, мелкие папки: полная %.0f мс, быстрая %.0f мс", fullTotal, fastTotal))
    }
}
