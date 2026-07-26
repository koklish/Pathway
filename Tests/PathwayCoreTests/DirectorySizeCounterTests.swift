import Foundation
import Testing
@testable import PathwayCore

@Suite("DirectorySizeCounter")
@MainActor
struct DirectorySizeCounterTests {

    /// Ждёт завершения обхода, опрашивая isFinished. Возврат по флагу, а не по
    /// таймеру: подсчёт кооперативный, точного времени у нас нет.
    private func waitUntilFinished(_ counter: DirectorySizeCounter, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !counter.isFinished {
            #expect(ContinuousClock.now < deadline, "обход не завершился за отведённое время")
            if ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    @Test("пустая папка: нулевой размер, isFinished становится true")
    func emptyFolder() async throws {
        try await withTempDirAsync { dir in
            let counter = DirectorySizeCounter()
            counter.start(roots: [dir])
            try await waitUntilFinished(counter)

            #expect(counter.progress.totalSize == 0)
            #expect(counter.progress.fileCount == 0)
            #expect(counter.isFinished)
        }
    }

    @Test("папка с файлами: суммирует размеры и считает файлы")
    func knownContents() async throws {
        try await withTempDirAsync { dir in
            try write(100, to: dir.appendingPathComponent("a.bin"))
            try write(200, to: dir.appendingPathComponent("b.bin"))
            try write(300, to: dir.appendingPathComponent("c.bin"))

            let counter = DirectorySizeCounter()
            counter.start(roots: [dir])
            try await waitUntilFinished(counter)

            #expect(counter.progress.totalSize == 600)
            #expect(counter.progress.fileCount == 3)
        }
    }

    @Test("вложенные папки: суммирует рекурсивно, считает подпапки")
    func nestedFolders() async throws {
        try await withTempDirAsync { dir in
            let sub = dir.appendingPathComponent("sub")
            let deep = sub.appendingPathComponent("deep")
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            try write(50, to: dir.appendingPathComponent("root.bin"))
            try write(50, to: sub.appendingPathComponent("mid.bin"))
            try write(50, to: deep.appendingPathComponent("leaf.bin"))

            let counter = DirectorySizeCounter()
            counter.start(roots: [dir])
            try await waitUntilFinished(counter)

            #expect(counter.progress.totalSize == 150)
            #expect(counter.progress.fileCount == 3)
            #expect(counter.progress.folderCount == 2)
        }
    }

    @Test("несколько корней: суммирует оба")
    func multipleRoots() async throws {
        try await withTempDirAsync { dir in
            let a = dir.appendingPathComponent("A")
            let b = dir.appendingPathComponent("B")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: false)
            try write(100, to: a.appendingPathComponent("x.bin"))
            try write(250, to: b.appendingPathComponent("y.bin"))

            let counter = DirectorySizeCounter()
            counter.start(roots: [a, b])
            try await waitUntilFinished(counter)

            #expect(counter.progress.totalSize == 350)
            #expect(counter.progress.fileCount == 2)
        }
    }

    @Test("cancel останавливает обход: isFinished не станет true задним числом")
    func cancelStopsCounting() async throws {
        try await withTempDirAsync { dir in
            // Много файлов, чтобы обход не успел завершиться до cancel.
            for i in 0..<500 {
                try write(10, to: dir.appendingPathComponent("f\(i).bin"))
            }

            let counter = DirectorySizeCounter()
            counter.start(roots: [dir])
            counter.cancel()

            // Даём отменённой задаче время не завершиться штатно.
            try await Task.sleep(for: .milliseconds(200))
            #expect(!counter.isFinished)
        }
    }

    @Test("символическая ссылка на родителя не зацикливает обход")
    func symlinkDoesNotLoop() async throws {
        try await withTempDirAsync { dir in
            try write(100, to: dir.appendingPathComponent("real.bin"))
            let link = dir.appendingPathComponent("loop")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)

            let counter = DirectorySizeCounter()
            counter.start(roots: [dir])
            try await waitUntilFinished(counter)

            // По ссылке не спускаемся: считаем только настоящий файл, не зависаем.
            #expect(counter.progress.totalSize == 100)
            #expect(counter.progress.fileCount == 1)
        }
    }
}
