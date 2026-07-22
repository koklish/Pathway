import Foundation
import Testing

@testable import PathwayCore

@Suite("Цель перетаскивания в списке")
struct DropTargetingTests {
    private let current = URL(fileURLWithPath: "/Users/tester/Current")
    private let folder = URL(fileURLWithPath: "/Users/tester/Current/Папка")

    /// Список из одной папки и одного файла.
    private let items = [URL(fileURLWithPath: "/Users/tester/Current/Папка")]

    /// Замыкание ведёт себя как настоящий код во вью: обращается к массиву
    /// по индексу. Если destination передаст сюда -1, тест упадёт так же,
    /// как падало приложение, — именно это и проверяется.
    private func itemAt(_ row: Int) -> URL? {
        guard row < items.count else { return nil }
        return items[row]
    }

    @Test("бросок на пустую область ниже строк не обращается к элементу по индексу -1")
    func emptyAreaDoesNotIndexOutOfBounds() {
        // AppKit передаёт row = -1, когда под курсором нет строки.
        // Раньше это роняло приложение обращением к model.items[-1].
        let destination = DropTargeting.destination(
            row: -1,
            isOnRow: true,
            isLocalDrag: false,
            itemAt: itemAt,
            currentFolder: current
        )

        #expect(destination == current)
    }

    @Test("бросок на строку-папку выбирает эту папку")
    func dropOnFolderRow() {
        let destination = DropTargeting.destination(
            row: 0,
            isOnRow: true,
            isLocalDrag: false,
            itemAt: itemAt,
            currentFolder: current
        )

        #expect(destination == folder)
    }

    @Test("бросок на строку-файл уходит в текущую папку")
    func dropOnFileRowFallsBackToCurrentFolder() {
        // Строка 1 — файл, itemAt возвращает nil.
        let destination = DropTargeting.destination(
            row: 1,
            isOnRow: true,
            isLocalDrag: false,
            itemAt: itemAt,
            currentFolder: current
        )

        #expect(destination == current)
    }

    @Test("бросок между строками уходит в текущую папку")
    func dropBetweenRows() {
        let destination = DropTargeting.destination(
            row: 0,
            isOnRow: false,
            isLocalDrag: false,
            itemAt: itemAt,
            currentFolder: current
        )

        #expect(destination == current)
    }

    @Test("перетаскивание внутри списка на пустое место не принимается")
    func localDragToEmptyAreaIsRejected() {
        let destination = DropTargeting.destination(
            row: -1,
            isOnRow: true,
            isLocalDrag: true,
            itemAt: itemAt,
            currentFolder: current
        )

        #expect(destination == nil)
    }

    @Test("перетаскивание внутри списка на папку принимается")
    func localDragOntoFolderIsAllowed() {
        let destination = DropTargeting.destination(
            row: 0,
            isOnRow: true,
            isLocalDrag: true,
            itemAt: itemAt,
            currentFolder: current
        )

        #expect(destination == folder)
    }

    @Test("строка за пределами списка не роняет и уходит в текущую папку")
    func rowBeyondEndFallsBack() {
        let destination = DropTargeting.destination(
            row: 999,
            isOnRow: true,
            isLocalDrag: false,
            itemAt: itemAt,
            currentFolder: current
        )

        #expect(destination == current)
    }
}
