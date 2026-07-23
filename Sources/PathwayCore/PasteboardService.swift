import AppKit
import Foundation

/// Что пользователь сделал с файлами: скопировал или вырезал.
public enum ClipboardOperation: String, Sendable {
    case copy
    case move
}

/// Работа с системным буфером обмена: копировать/вырезать файлы совместимо с Finder.
@MainActor
public struct PasteboardService {
    /// Приватный тип для пометки «вырезано». Finder такой пометки не понимает —
    /// для него вырезанные файлы выглядят как обычное копирование, и это правильно:
    /// перемещение выполняет Pathway при вставке.
    private static let operationType = NSPasteboard.PasteboardType("com.pathway.clipboard-operation")

    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Буфер, не связанный с системным — чтобы тесты не трогали буфер пользователя.
    public init(isolatedForTesting: Bool) {
        self.pasteboard = isolatedForTesting
            ? NSPasteboard(name: .init("PathwayIsolated-\(UUID().uuidString)"))
            : .general
    }

    public func write(_ urls: [URL], operation: ClipboardOperation) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        pasteboard.setString(operation.rawValue, forType: Self.operationType)
    }

    /// Кладёт в буфер текст. `clearContents` обязателен: без него URL от
    /// прошлого «Копировать» остались бы в буфере, и «Вставить» скопировала бы
    /// сам файл вместо ожидаемой строки.
    public func writeText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public func readText() -> String? {
        pasteboard.string(forType: .string)
    }

    public func readURLs() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (objects as? [URL]) ?? []
    }

    public func readOperation() -> ClipboardOperation {
        guard let raw = pasteboard.string(forType: Self.operationType),
              let operation = ClipboardOperation(rawValue: raw)
        else { return .copy }
        return operation
    }

    public var hasFiles: Bool {
        !readURLs().isEmpty
    }
}
