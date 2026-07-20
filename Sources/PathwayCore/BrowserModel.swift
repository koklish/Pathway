import AppKit
import Foundation
import Observation

/// Сегмент пути в адресной строке.
public struct Breadcrumb: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
}

/// Связывает навигацию, чтение папки и файловые операции для одной панели.
@Observable
@MainActor
public final class BrowserModel {
    public let pane: PaneState
    public private(set) var items: [FileItem] = []
    public var errorMessage: String?
    public var showHiddenFiles = false
    public var operationProgress: Double?

    private let loader = DirectoryLoader()
    private let operations = FileOperations()
    private let pasteboard: PasteboardService
    private var sortKey = "name"
    private var sortAscending = true

    public init(path: URL, pasteboard: PasteboardService = PasteboardService()) {
        self.pane = PaneState(path: path)
        self.pasteboard = pasteboard
    }

    public var breadcrumbs: [Breadcrumb] {
        var crumbs = [Breadcrumb(url: URL(fileURLWithPath: "/"), name: "Macintosh HD")]
        var accumulated = ""
        for component in pane.path.pathComponents.dropFirst() {
            accumulated += "/" + component
            crumbs.append(Breadcrumb(url: URL(fileURLWithPath: accumulated), name: component))
        }
        return crumbs
    }

    public var statusText: String {
        let folders = items.filter(\.isDirectory).count
        var text = "Папок: \(folders), файлов: \(items.count - folders)"
        if !pane.selection.isEmpty {
            text += " · Выделено: \(pane.selection.count)"
        }
        return text
    }

    // MARK: - Загрузка и навигация

    public func reload() {
        do {
            items = sorted(try loader.load(directory: pane.path, showHidden: showHiddenFiles))
        } catch {
            items = []
            errorMessage = Self.describe(error, at: pane.path)
        }
    }

    public func navigate(to url: URL) {
        pane.navigate(to: url)
        reload()
    }

    public func open(_ item: FileItem) {
        if item.isDirectory {
            navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    /// Подпапки для дерева в сайдбаре. Недоступные папки — просто пустой список:
    /// раскрытие узла не должно показывать алерт.
    public func subdirectories(of url: URL) -> [FileItem] {
        let contents = (try? loader.load(directory: url, showHidden: showHiddenFiles)) ?? []
        return contents.filter(\.isDirectory)
    }

    // MARK: - Сортировка и отображение

    public func sort(by key: String, ascending: Bool) {
        sortKey = key
        sortAscending = ascending
        items = sorted(items)
    }

    private func sorted(_ list: [FileItem]) -> [FileItem] {
        list.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let result: Bool
            switch sortKey {
            case "size": result = a.size < b.size
            case "modified": result = (a.modificationDate ?? .distantPast) < (b.modificationDate ?? .distantPast)
            case "kind": result = a.url.pathExtension.localizedStandardCompare(b.url.pathExtension) == .orderedAscending
            default: result = a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return sortAscending ? result : !result
        }
    }

    public func text(for item: FileItem, column: String) -> String {
        switch column {
        case "size":
            return item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        case "modified":
            guard let date = item.modificationDate else { return "—" }
            return date.formatted(date: .abbreviated, time: .shortened)
        case "kind":
            return Self.kindLabel(for: item)
        default:
            return item.name
        }
    }

    private static func kindLabel(for item: FileItem) -> String {
        if item.isDirectory { return "Папка" }
        let ext = item.url.pathExtension
        return ext.isEmpty ? "Документ" : ext.uppercased()
    }

    // MARK: - Файловые операции

    public func createFolder() {
        run { try operations.createFolder(in: pane.path) }
    }

    public func rename(_ url: URL, to newName: String) {
        run { _ = try operations.rename(url, to: newName) }
    }

    public func copy() {
        guard !pane.selection.isEmpty else { return }
        pasteboard.write(Array(pane.selection), operation: .copy)
        pane.clearCut()
    }

    public func cut() {
        guard !pane.selection.isEmpty else { return }
        let urls = Array(pane.selection)
        pasteboard.write(urls, operation: .move)
        pane.markCut(urls)
    }

    public func paste() {
        let urls = pasteboard.readURLs()
        guard !urls.isEmpty else { return }
        let operation = pasteboard.readOperation()
        run {
            if operation == .move {
                _ = try operations.move(urls, to: pane.path)
                pane.clearCut()
            } else {
                _ = try operations.copy(urls, to: pane.path)
            }
        }
    }

    public func copy(_ urls: [URL], to destination: URL) {
        run { _ = try operations.copy(urls, to: destination) }
    }

    public func move(_ urls: [URL], to destination: URL) {
        run { _ = try operations.move(urls, to: destination) }
    }

    public func moveSelectionToTrash() {
        let urls = Array(pane.selection)
        guard !urls.isEmpty else { return }
        run {
            try operations.moveToTrash(urls)
            pane.selection = []
        }
    }

    /// Выполняет операцию, показывает понятную ошибку и обновляет список.
    private func run(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            errorMessage = Self.describe(error, at: pane.path)
        }
        reload()
    }

    // MARK: - Ошибки

    private static func describe(_ error: any Error, at path: URL) -> String {
        if let operationError = error as? FileOperationError {
            switch operationError {
            case .invalidName:
                return "Недопустимое имя. Имя не может быть пустым или содержать «/» и «:»."
            case .nameAlreadyExists:
                return "Объект с таким именем уже существует в этой папке."
            }
        }
        let nsError = error as NSError
        switch nsError.code {
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
            return "Нет доступа к «\(path.lastPathComponent)». Выдайте приложению полный доступ к диску в Настройках → Конфиденциальность и безопасность."
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return "Папка «\(path.lastPathComponent)» больше не существует."
        case NSFileWriteOutOfSpaceError:
            return "Недостаточно места на диске."
        default:
            return nsError.localizedDescription
        }
    }
}
