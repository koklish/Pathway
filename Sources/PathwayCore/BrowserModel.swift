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

    /// true, пока идёт чтение папки — для индикатора в интерфейсе.
    public private(set) var isLoading = false

    private let loader = DirectoryLoader()
    private let operations = FileOperations()
    private let pasteboard: PasteboardService
    private let cache = DirectoryCache()
    private var sortKey = "name"
    private var sortAscending = true
    /// Текущая загрузка: при быстром переключении папок предыдущая отменяется,
    /// иначе медленный сетевой ответ перезапишет уже открытую папку.
    private var loadTask: Task<Void, Never>?

    public init(path: URL, pasteboard: PasteboardService = PasteboardService()) {
        self.pane = PaneState(path: path)
        self.pasteboard = pasteboard
    }

    public var breadcrumbs: [Breadcrumb] {
        var crumbs = [Breadcrumb(url: URL(fileURLWithPath: "/"), name: "Этот Мас")]
        var accumulated = ""
        for component in pane.path.pathComponents.dropFirst() {
            accumulated += "/" + component
            let url = URL(fileURLWithPath: accumulated)
            crumbs.append(Breadcrumb(url: url, name: Self.displayName(for: url, component: component)))
        }
        return crumbs
    }

    /// Имя сегмента так, как его показывает Finder: локализованное, если система его переводит.
    private static func displayName(for url: URL, component: String) -> String {
        let localized = FileManager.default.displayName(atPath: url.path)
        return localized.isEmpty ? component : localized
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

    /// Синхронная загрузка — для тестов и файловых операций, где нужен готовый результат.
    public func reload() {
        do {
            let loaded = sorted(try loader.load(directory: pane.path, showHidden: showHiddenFiles))
            cache.store(loaded, for: pane.path, showHidden: showHiddenFiles)
            items = loaded
        } catch {
            items = []
            errorMessage = Self.describe(error, at: pane.path)
        }
    }

    /// Загрузка для интерфейса: не блокирует главный поток.
    ///
    /// Порядок такой, чтобы окно оставалось живым на медленных дисках:
    /// сначала кэш (мгновенно), затем имена из фонового потока, затем метаданные.
    public func reloadAsync() {
        let directory = pane.path
        let showHidden = showHiddenFiles

        // Уже открытую папку показываем сразу, не дожидаясь диска.
        if let cached = cache.items(for: directory, showHidden: showHidden) {
            items = sorted(cached)
        }
        let hadCache = !items.isEmpty && cache.items(for: directory, showHidden: showHidden) != nil

        loadTask?.cancel()
        loadTask = Task { [loader] in
            if !hadCache { isLoading = true }
            defer { isLoading = false }

            do {
                // Обход каталога — самая дорогая часть, уводим её с главного потока.
                let names = try await Task.detached(priority: .userInitiated) {
                    try loader.loadNames(directory: directory, showHidden: showHidden)
                }.value

                guard !Task.isCancelled, pane.path == directory else { return }
                items = sorted(names)

                // Метаданные добираем следом: список уже виден и кликабелен.
                let detailed = await Task.detached(priority: .utility) {
                    loader.loadMetadata(for: names)
                }.value

                guard !Task.isCancelled, pane.path == directory else { return }
                cache.store(detailed, for: directory, showHidden: showHidden)
                items = sorted(detailed)
            } catch {
                guard !Task.isCancelled, pane.path == directory else { return }
                items = []
                errorMessage = Self.describe(error, at: directory)
            }
        }
    }

    public func navigate(to url: URL) {
        pane.navigate(to: url)
        reloadAsync()
    }

    /// Ждёт завершения текущей фоновой загрузки. Нужно тестам и коду,
    /// которому важен готовый список сразу после перехода.
    public func waitForLoad() async {
        await loadTask?.value
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
        let contents = (try? loader.loadNames(directory: url, showHidden: showHiddenFiles)) ?? []
        return contents.filter(\.isDirectory)
    }

    /// Подпапки для дерева, прочитанные вне главного потока.
    ///
    /// Раскрытие узла на сетевом диске стоит сотни миллисекунд — синхронное чтение
    /// подвесило бы весь сайдбар.
    public func subdirectoriesAsync(of url: URL) async -> [FileItem] {
        let showHidden = showHiddenFiles
        return await Task.detached(priority: .userInitiated) { [loader] in
            let contents = (try? loader.loadNames(directory: url, showHidden: showHidden)) ?? []
            let directories = contents.filter(\.isDirectory)
            // В дереве сетевые тома не показываем: ими управляют из секции «Сеть»,
            // а здесь они были бы вторым, неуправляемым вхождением того же диска.
            // В списке файлов /Volumes при этом остаётся полным.
            return directories.filter { !Self.isNetworkVolume($0.url) }
        }.value
    }

    /// Точка монтирования сетевого тома: /Volumes/… на неместной файловой системе.
    /// nonisolated — проверка чистая и вызывается из фонового чтения каталога.
    private nonisolated static func isNetworkVolume(_ url: URL) -> Bool {
        guard url.deletingLastPathComponent().path == "/Volumes" else { return false }
        return (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
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
        cache.invalidate(destination)
        run { _ = try operations.copy(urls, to: destination) }
    }

    public func move(_ urls: [URL], to destination: URL) {
        cache.invalidate(destination)
        urls.forEach { cache.invalidate($0.deletingLastPathComponent()) }
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
        // Содержимое папки изменилось — кэш устарел, читаем заново.
        cache.invalidate(pane.path)
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
