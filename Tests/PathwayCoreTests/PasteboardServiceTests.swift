import AppKit
import Foundation
import Testing
@testable import PathwayCore

@MainActor
@Suite("PasteboardService")
struct PasteboardServiceTests {
    /// Отдельный буфер обмена для тестов — системный не трогаем.
    private func makeService() -> (PasteboardService, NSPasteboard) {
        let pasteboard = NSPasteboard(name: .init("PathwayTests-\(UUID().uuidString)"))
        return (PasteboardService(pasteboard: pasteboard), pasteboard)
    }

    @Test("кладёт файлы в буфер и читает их обратно")
    func writesAndReadsURLs() {
        let (service, _) = makeService()
        let files = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]

        service.write(files, operation: .copy)

        #expect(service.readURLs() == files)
    }

    @Test("запоминает режим операции: копирование или перемещение")
    func remembersOperation() {
        let (service, _) = makeService()
        let files = [URL(fileURLWithPath: "/tmp/a.txt")]

        service.write(files, operation: .move)
        #expect(service.readOperation() == .move)

        service.write(files, operation: .copy)
        #expect(service.readOperation() == .copy)
    }

    @Test("на пустом буфере возвращает пустой список")
    func emptyPasteboardReturnsNoURLs() {
        let (service, _) = makeService()

        #expect(service.readURLs().isEmpty)
        #expect(!service.hasFiles)
    }

    @Test("сообщает о наличии файлов в буфере")
    func reportsAvailability() {
        let (service, _) = makeService()

        service.write([URL(fileURLWithPath: "/tmp/a.txt")], operation: .copy)

        #expect(service.hasFiles)
    }

    @Test("новая запись заменяет предыдущее содержимое буфера")
    func writeReplacesPreviousContents() {
        let (service, _) = makeService()
        service.write([URL(fileURLWithPath: "/tmp/first.txt")], operation: .copy)

        service.write([URL(fileURLWithPath: "/tmp/second.txt")], operation: .copy)

        #expect(service.readURLs().map(\.lastPathComponent) == ["second.txt"])
    }
}
