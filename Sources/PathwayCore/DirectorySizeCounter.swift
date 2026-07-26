import Foundation

/// Промежуточный итог обхода дерева. Растёт по мере чтения; UI показывает его
/// в реальном времени.
public struct SizeProgress: Sendable, Equatable {
    public var totalSize: Int64 = 0
    public var fileCount: Int = 0
    public var folderCount: Int = 0

    public init(totalSize: Int64 = 0, fileCount: Int = 0, folderCount: Int = 0) {
        self.totalSize = totalSize
        self.fileCount = fileCount
        self.folderCount = folderCount
    }
}

/// Рекурсивный подсчёт размера папок с прогрессом. Отдельный тип, а не метод
/// BrowserModel: живёт ровно столько, сколько открыт лист свойств, и имеет свой
/// жизненный цикл — start на .onAppear, cancel на .onDisappear.
@MainActor
public final class DirectorySizeCounter: ObservableObject {
    @Published public private(set) var progress = SizeProgress()
    @Published public private(set) var isFinished = false

    private var task: Task<Void, Never>?

    public init() {}

    /// Запускает обход переданных корней. Повторный вызов отменяет прежний.
    public func start(roots: [URL]) {
        task?.cancel()
        progress = SizeProgress()
        isFinished = false

        let paths = roots.map(\.path)
        task = Task { [weak self] in
            // Обход на .utility — ниже интерактивного, как третья ступень
            // загрузки каталога: размер папки не должен мешать прокрутке.
            let stream = await Task.detached(priority: .utility) {
                Self.walk(paths: paths)
            }.value

            // Слив итога в @Published раз в ~200 мс, а не на каждый файл: на SMB
            // тысячи обновлений в секунду захлебнули бы главный поток. Порог по
            // времени, накопленное отдаётся целиком.
            guard let self else { return }
            for await snapshot in stream {
                if Task.isCancelled { return }
                self.progress = snapshot
            }
            if Task.isCancelled { return }
            self.isFinished = true
        }
    }

    /// Останавливает обход. Зовётся при закрытии листа.
    public func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: - Обход

    /// Порог слива прогресса. 200 мс — компромисс: чаще нет смысла (глаз не
    /// различит), реже — счётчик выглядел бы застывшим.
    private nonisolated static let flushInterval: TimeInterval = 0.2

    /// Обходит дерево через opendir/readdir и шлёт снимки прогресса в поток.
    /// nonisolated и синхронный: вызывается внутри Task.detached.
    private nonisolated static func walk(paths: [String]) -> AsyncStream<SizeProgress> {
        AsyncStream { continuation in
            var progress = SizeProgress()
            var lastFlush = Date.distantPast

            func flush(force: Bool) {
                let now = Date()
                if force || now.timeIntervalSince(lastFlush) >= flushInterval {
                    lastFlush = now
                    continuation.yield(progress)
                }
            }

            // Итеративный обход стеком, а не рекурсией: глубокое дерево не должно
            // упереться в лимит стека потока.
            var stack = paths
            while let path = stack.popLast() {
                if Task.isCancelled { break }
                guard let handle = opendir(path) else { continue }
                let base = path.hasSuffix("/") ? path : path + "/"

                while let entry = readdir(handle) {
                    if Task.isCancelled { break }
                    var raw = entry.pointee.d_name
                    let name = withUnsafePointer(to: &raw) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                    }
                    if name == "." || name == ".." { continue }
                    let full = base + name
                    let type = entry.pointee.d_type

                    // Символические ссылки не разыменовываем и по ним не
                    // спускаемся: ссылка на родителя иначе зациклила бы обход.
                    if type == DT_LNK { continue }

                    if type == DT_DIR {
                        progress.folderCount += 1
                        stack.append(full)
                    } else if type == DT_REG {
                        var info = stat()
                        if lstat(full, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG {
                            progress.totalSize += Int64(info.st_size)
                            progress.fileCount += 1
                        }
                    } else if type == DT_UNKNOWN {
                        // Файловая система не отдала тип в d_type — доспрашиваем
                        // stat. Ссылки уже отсеяны выше по d_type; здесь lstat
                        // тоже не разыменовывает, поэтому цикл невозможен.
                        var info = stat()
                        guard lstat(full, &info) == 0 else { continue }
                        switch info.st_mode & S_IFMT {
                        case S_IFDIR:
                            progress.folderCount += 1
                            stack.append(full)
                        case S_IFREG:
                            progress.totalSize += Int64(info.st_size)
                            progress.fileCount += 1
                        default:
                            break
                        }
                    }

                    flush(force: false)
                }
                closedir(handle)
            }

            flush(force: true)
            continuation.finish()
        }
    }
}
