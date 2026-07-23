import Foundation
import Testing
@testable import PathwayCore

@MainActor
@Suite("Копирование пути в буфер")
struct CopyPathTests {
    @Test("кладёт в буфер путь выделенного файла, а не его имя")
    func copiesFullPath() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("файл.txt")
            try Data("x".utf8).write(to: file)

            let pasteboard = PasteboardService(isolatedForTesting: true)
            let model = BrowserModel(path: dir, pasteboard: pasteboard)
            model.reload()
            let url = try #require(model.items.first).url
            model.pane.selection = [url]

            model.copyPath()

            #expect(pasteboard.readText() == url.path)
        }
    }

    @Test("без выделения копирует путь открытой папки")
    func fallsBackToCurrentFolder() throws {
        try withTempDir { dir in
            let pasteboard = PasteboardService(isolatedForTesting: true)
            let model = BrowserModel(path: dir, pasteboard: pasteboard)
            model.reload()

            model.copyPath()

            #expect(pasteboard.readText() == model.pane.path.path)
        }
    }

    @Test("при нескольких выделенных объектах копирует все пути по строке на каждый")
    func copiesEverySelectedPath() throws {
        try withTempDir { dir in
            for name in ["а.txt", "б.txt"] {
                try Data("x".utf8).write(to: dir.appendingPathComponent(name))
            }

            let pasteboard = PasteboardService(isolatedForTesting: true)
            let model = BrowserModel(path: dir, pasteboard: pasteboard)
            model.reload()
            model.pane.selection = Set(model.items.map(\.url))

            model.copyPath()

            // Порядок как в списке, а не как в Set: иначе две строки приходили
            // бы читателю в случайном порядке при каждом вызове.
            #expect(pasteboard.readText() == model.items.map(\.url.path).joined(separator: "\n"))
        }
    }

    @Test("копирует путь папки из сайдбара, а не открытой в списке")
    func copiesSidebarFolder() throws {
        try withTempDir { dir in
            let other = dir.appendingPathComponent("другая")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)

            let pasteboard = PasteboardService(isolatedForTesting: true)
            let model = BrowserModel(path: dir, pasteboard: pasteboard)
            model.reload()

            model.copyPath([other])

            #expect(pasteboard.readText() == other.path)
        }
    }

    @Test("копирует путь кликнутого файла, а не выделенного")
    func copiesExplicitURL() throws {
        try withTempDir { dir in
            for name in ["а.txt", "б.txt"] {
                try Data("x".utf8).write(to: dir.appendingPathComponent(name))
            }

            let pasteboard = PasteboardService(isolatedForTesting: true)
            let model = BrowserModel(path: dir, pasteboard: pasteboard)
            model.reload()
            let clicked = try #require(model.items.last).url
            model.pane.selection = [try #require(model.items.first).url]

            model.copyPath([clicked])

            #expect(pasteboard.readText() == clicked.path)
        }
    }
}
