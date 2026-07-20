import Foundation
import Observation

/// Состояние панели: текущая папка, история навигации, выделение.
@Observable
@MainActor
public final class PaneState {
    public private(set) var path: URL
    public var selection: Set<URL> = []
    public private(set) var cutItems: Set<URL> = []

    private var history: [URL]
    private var historyIndex: Int

    public init(path: URL) {
        let normalized = Self.normalize(path)
        self.path = normalized
        self.history = [normalized]
        self.historyIndex = 0
    }

    /// Приводит URL к каноничному виду: без хвостового слэша, чтобы один и тот же
    /// путь всегда сравнивался как равный (deletingLastPathComponent добавляет слэш).
    private static func normalize(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path)
    }

    // MARK: - Навигация

    public var canGoBack: Bool { historyIndex > 0 }
    public var canGoForward: Bool { historyIndex < history.count - 1 }

    public func navigate(to url: URL) {
        let target = Self.normalize(url)
        guard target != path else { return }
        history.removeSubrange((historyIndex + 1)...)
        history.append(target)
        historyIndex = history.count - 1
        setPath(target)
    }

    public func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        setPath(history[historyIndex])
    }

    public func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        setPath(history[historyIndex])
    }

    public func goUp() {
        let parent = path.deletingLastPathComponent()
        guard parent.path != path.path else { return }
        navigate(to: parent)
    }

    private func setPath(_ url: URL) {
        path = url
        selection = []
    }

    // MARK: - Вырезанные файлы

    public func markCut(_ urls: [URL]) {
        cutItems = Set(urls)
    }

    public func clearCut() {
        cutItems = []
    }

    public func isCut(_ url: URL) -> Bool {
        cutItems.contains(url)
    }
}
