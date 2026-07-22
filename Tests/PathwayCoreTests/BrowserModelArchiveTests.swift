import Foundation
import Testing
@testable import PathwayCore

@MainActor
@Suite("BrowserModel — архивация и распаковка")
struct BrowserModelArchiveTests {

    private func makeFolder(in dir: URL, name: String = "Материалы") throws -> URL {
        let folder = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("привет".utf8).write(to: folder.appendingPathComponent("файл.txt"))
        return folder
    }

    private func item(_ model: BrowserModel, _ name: String) throws -> FileItem {
        try #require(model.items.first { $0.name == name })
    }

    @Test("архивирует выделенную папку в текущую папку")
    func compressesFolder() async throws {
        try await withTempDirAsync { dir in
            let folder = try makeFolder(in: dir)
            let model = BrowserModel(path: dir)
            model.reload()

            model.compress(items: [FileItem(url: folder, name: folder.lastPathComponent, isDirectory: true)], format: .zip, password: nil, name: "Архив")
            await model.waitForOperation()

            #expect(model.errorMessage == nil)
            #expect(model.items.contains { $0.name == "Архив.zip" })
            #expect(model.operationProgress == nil)
            #expect(model.operationTitle == nil)
        }
    }

    @Test("открытие архива распаковывает его рядом с архивом")
    func openExtractsArchiveInPlace() async throws {
        try await withTempDirAsync { dir in
            let folder = try makeFolder(in: dir)
            let model = BrowserModel(path: dir)
            model.reload()
            model.compress(items: [FileItem(url: folder, name: folder.lastPathComponent, isDirectory: true)], format: .zip, password: nil, name: "Архив")
            await model.waitForOperation()

            model.open(try item(model, "Архив.zip"))
            await model.waitForOperation()

            #expect(model.errorMessage == nil)
            // Внутри один элемент верхнего уровня «Материалы» — рядом появляется «Материалы 2».
            #expect(model.items.contains { $0.name == "Материалы 2" })
        }
    }

    @Test("распаковка в выбранную папку")
    func extractsToChosenDirectory() async throws {
        try await withTempDirAsync { dir in
            let folder = try makeFolder(in: dir)
            let target = dir.appendingPathComponent("Цель")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let model = BrowserModel(path: dir)
            model.reload()
            model.compress(items: [FileItem(url: folder, name: folder.lastPathComponent, isDirectory: true)], format: .zip, password: nil, name: "Архив")
            await model.waitForOperation()

            model.extract(try item(model, "Архив.zip"), to: target)
            await model.waitForOperation()

            #expect(model.errorMessage == nil)
            let extracted = target.appendingPathComponent("Материалы/файл.txt")
            #expect(FileManager.default.fileExists(atPath: extracted.path))
        }
    }

    @Test("зашифрованный архив запрашивает пароль, после ввода распаковывается")
    func encryptedArchiveAsksForPassword() async throws {
        try await withTempDirAsync { dir in
            let folder = try makeFolder(in: dir)
            let model = BrowserModel(path: dir)
            model.reload()
            model.compress(items: [FileItem(url: folder, name: folder.lastPathComponent, isDirectory: true)], format: .zip, password: "секрет", name: "Тайна")
            await model.waitForOperation()

            model.open(try item(model, "Тайна.zip"))
            await model.waitForOperation()

            let request = try #require(model.passwordRequest)
            #expect(!request.wasWrong)
            #expect(model.errorMessage == nil)

            model.submitPassword("секрет")
            await model.waitForOperation()

            #expect(model.passwordRequest == nil)
            #expect(model.items.contains { $0.name == "Материалы 2" })
        }
    }

    @Test("неверный пароль запрашивает пароль повторно с пометкой")
    func wrongPasswordAsksAgain() async throws {
        try await withTempDirAsync { dir in
            let folder = try makeFolder(in: dir)
            let model = BrowserModel(path: dir)
            model.reload()
            model.compress(items: [FileItem(url: folder, name: folder.lastPathComponent, isDirectory: true)], format: .zip, password: "секрет", name: "Тайна")
            await model.waitForOperation()

            model.open(try item(model, "Тайна.zip"))
            await model.waitForOperation()
            model.submitPassword("не тот")
            await model.waitForOperation()

            let request = try #require(model.passwordRequest)
            #expect(request.wasWrong)

            model.cancelPasswordRequest()
            #expect(model.passwordRequest == nil)
        }
    }
}
