import Foundation
import Observation

/// Состояние поиска: запрос, находки, ход выполнения.
///
/// Отдельно от `BrowserModel`, а не полем в нём: поиск живёт своим циклом —
/// запускается, идёт, отменяется, — и подмешивать его в модель папки значило бы
/// путать два независимых состояния. Список файлов подменяется результатами на
/// уровне вью.
@Observable
@MainActor
public final class SearchModel {
    /// Текст в поле поиска. Правится вводом, поиск с него не начинается:
    /// запуск по Enter.
    public var query = ""

    public private(set) var results: [SearchResult] = []
    public private(set) var isSearching = false
    /// Запрос, по которому получена текущая выдача. Отличается от `query`, пока
    /// пользователь правит текст, — по нему подписывается результат.
    public private(set) var activeQuery = ""
    /// Папка, в которой шёл поиск: нужна для показа путей относительно неё.
    public private(set) var root: URL?
    public private(set) var report = SearchReport()
    public private(set) var progress = SearchProgress()
    public private(set) var errorMessage: String?

    /// Доля выполненного, 0…1 — не убывающая.
    ///
    /// Оценка движка может упасть: очередь обхода пополняется, когда находится
    /// ветка глубже ожидаемой. Полоса, едущая назад, читается как сбой, поэтому
    /// показываем достигнутый максимум и ждём, пока реальность его догонит.
    /// Само значение в `progress` при этом честное — гасится только показ.
    public private(set) var fraction: Double = 0

    /// Поиск запускался хотя бы раз — отличает «ничего не найдено» от «ещё не
    /// искали»: в первом случае показывается пустое состояние, во втором список
    /// файлов.
    public private(set) var isActive = false

    private let engine: SearchEngine
    private let archives: ArchiveService
    private var task: Task<Void, Never>?

    public init(engine: SearchEngine = SearchEngine(), archives: ArchiveService = ArchiveService()) {
        self.engine = engine
        self.archives = archives
    }

    /// Запускает поиск в папке. Прошлый отменяется — иначе две выдачи
    /// смешались бы в одном списке.
    public func search(in directory: URL, ignoringSizeLimit: Bool = false) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        task?.cancel()
        isActive = true
        isSearching = true
        results = []
        report = SearchReport()
        progress = SearchProgress()
        fraction = 0
        errorMessage = nil
        activeQuery = trimmed
        root = directory

        task = Task { [engine] in
            for await event in engine.search(query: trimmed, in: directory, ignoringSizeLimit: ignoringSizeLimit) {
                if Task.isCancelled { return }
                switch event {
                case .results(let batch):
                    // Порции дописываются в конец, а показанные строки не
                    // двигаются. Пересортировка всей выдачи на каждой порции
                    // выглядела бы лучше по релевантности, но список прыгал бы
                    // под курсором: кликнуть по находке, не дождавшись конца
                    // поиска, стало бы невозможно. Внутри порции порядок по
                    // совпадению остаётся — его расставляет движок.
                    results.append(contentsOf: batch)
                case .progress(let current):
                    progress = current
                    fraction = max(fraction, current.fraction)
                case .finished(let final):
                    report = final
                    // Поиск кончился — полоса обязана дойти до края. Оценка
                    // могла остановиться чуть раньше: доля первой фазы всё
                    // время была приближением.
                    fraction = 1
                }
            }
            isSearching = false
        }
    }

    /// Повторяет поиск, вскрывая и те архивы, что были пропущены по размеру.
    public func searchIncludingSkipped() {
        guard let root else { return }
        query = activeQuery
        search(in: root, ignoringSizeLimit: true)
    }

    /// Закрывает выдачу, оставляя текст запроса в поле.
    ///
    /// Для перехода к находке: человек ушёл в её папку, но запрос ему ещё
    /// нужен — Enter должен вернуть ту же выдачу, не заставляя набирать
    /// заново. Отдельный метод, а не порядок вызовов во вью: переход меняет
    /// путь, а это само по себе закрывает поиск через cancel, и
    /// восстановленный снаружи запрос тут же стирался бы обратно.
    public func closeKeepingQuery() {
        let text = activeQuery
        cancel()
        query = text
    }

    /// Закрывает поиск и возвращает список файлов.
    public func cancel() {
        task?.cancel()
        task = nil
        isSearching = false
        isActive = false
        results = []
        report = SearchReport()
        progress = SearchProgress()
        fraction = 0
        errorMessage = nil
        query = ""
    }

    /// Готовит находку к открытию.
    ///
    /// Файл с диска отдаётся как есть, запись архива сначала извлекается во
    /// временную папку. Возвращает `nil`, если извлечь не удалось: текст ошибки
    /// уже лежит в `errorMessage`.
    public func fileToOpen(for result: SearchResult) async -> URL? {
        switch result.source {
        case .file:
            return result.url
        case .archiveEntry(let path):
            do {
                return try await archives.extractEntry(path, from: result.url)
            } catch {
                errorMessage = Self.describe(error, entry: path)
                return nil
            }
        }
    }

    public func dismissError() { errorMessage = nil }

    /// Путь находки для буфера обмена.
    ///
    /// У записи архива своего пути на диске нет, поэтому отдаётся путь архива
    /// с записью через «›» — та же запись, что в строке выдачи. Голый путь
    /// архива не сказал бы, что именно нашлось.
    public func pathForClipboard(_ result: SearchResult) -> String {
        switch result.source {
        case .file: result.url.path
        case .archiveEntry(let path): "\(result.url.path) › \(path)"
        }
    }

    /// Текст ошибки рождается в Core, UI его только показывает — как везде в
    /// проекте.
    private static func describe(_ error: Error, entry: String) -> String {
        switch error {
        case ArchiveError.passwordRequired, ArchiveError.wrongPassword:
            "Архив защищён паролем. Откройте его из списка файлов, чтобы ввести пароль."
        case ArchiveError.encryptedUnsupported:
            "Этот формат шифрования не поддерживается. Распакуйте архив сторонней программой."
        default:
            "Не удалось извлечь «\((entry as NSString).lastPathComponent)» из архива."
        }
    }
}
