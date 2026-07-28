import Foundation
import PDFKit

/// Граница с системой: чтение текста из файла.
///
/// Протокол — по общему правилу проекта о границах с ОС. Без него тесты движка
/// поиска требовали бы настоящих `.docx` и `.pdf` на диске, и проверить, что
/// содержимое **не** читалось при выключенном режиме, стало бы нечем.
public protocol TextExtracting: Sendable {
    /// Текст файла либо `nil`, если из этого формата текст не достаётся.
    ///
    /// `nil` — не ошибка: для картинки или бинарника это ожидаемый исход.
    /// Ошибка бросается, только когда файл заявлен читаемым, но прочитать его
    /// не удалось.
    func text(of url: URL) async throws -> String?
}

public enum TextExtractionError: Error, Equatable {
    case unreadableContainer(String)
}

/// Читает текст, выбирая способ по расширению.
///
/// Три ветки, и разница между ними принципиальная:
///
/// - **обычный текст** — чтение с диска и декодирование;
/// - **OOXML** (`.docx`/`.xlsx`/`.pptx`) — это ZIP: нужные части извлекаются
///   `bsdtar`, после чего снимаются XML-теги;
/// - **PDF** — `PDFKit`.
///
/// `PDFKit` в Core не нарушает границу проекта: она проведена по «нет типов,
/// которые рисуют», а `PDFDocument` здесь — системный сервис чтения, как
/// `NSWorkspace` и `NSPasteboard` в других файлах Core.
public struct SystemTextExtractor: TextExtracting {
    public init() {}

    /// Расширения обычного текста. Исходники наравне с документами: проект
    /// живёт в ИТ, и «найти файл кода с нужной строкой» — такой же реальный
    /// сценарий, как «найти договор с упоминанием контрагента».
    static let plainExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "log", "json", "xml", "yml", "yaml",
        "ini", "conf", "cfg", "plist", "rtf", "srt", "sql", "sh", "bash", "zsh",
        "swift", "php", "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs", "java",
        "kt", "c", "h", "cpp", "hpp", "m", "mm", "cs", "html", "htm", "css", "scss",
        "env", "gitignore", "podspec", "gradle", "toml", "properties", "patch", "diff",
    ]

    /// Контейнеры OOXML и шаблоны частей, в которых лежит видимый текст.
    ///
    /// Части отбираются шаблоном, а не берётся весь архив: рядом лежат стили и
    /// темы, чей XML дал бы совпадения по служебным словам вроде «Calibri» —
    /// находка, которую нечем объяснить.
    ///
    /// Шаблоны, а не точные имена: части необязательны — сноски есть не в
    /// каждом документе, `sharedStrings.xml` отсутствует у таблицы без
    /// текстовых ячеек, — а `bsdtar` на явно названной и отсутствующей записи
    /// выходит с ошибкой, и такой документ не прочитался бы вовсе.
    static let ooxmlParts: [String: [String]] = [
        "docx": ["word/*.xml"],
        "xlsx": ["xl/sharedStrings.xml", "xl/worksheets/*"],
        "pptx": ["ppt/slides/*", "ppt/notesSlides/*"],
    ]

    /// Файл, из которого имеет смысл читать текст.
    ///
    /// Статическая и без обращения к диску: обход каталога отбирает кандидатов
    /// на лету, и любой запрос к файловой системе здесь стоил бы того же, что
    /// весь обход. `.doc` и `.xls` в список не входят — см. спеку.
    public static func isReadable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return plainExtensions.contains(ext) || ooxmlParts[ext] != nil || ext == "pdf"
    }

    public func text(of url: URL) async throws -> String? {
        let ext = url.pathExtension.lowercased()
        if let parts = Self.ooxmlParts[ext] { return try await Self.ooxmlText(of: url, parts: parts) }
        if ext == "pdf" { return Self.pdfText(of: url) }
        guard Self.plainExtensions.contains(ext) else { return nil }
        return try Self.plainText(of: url)
    }

    // MARK: - Обычный текст

    /// Сколько байт нюхаем на бинарность. Килобайта хватает: нулевой байт в
    /// настоящем бинарнике встречается в первых же структурах заголовка.
    private static let sniffLength = 1024

    private static func plainText(of url: URL) throws -> String? {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)

        // Проверка по содержимому в дополнение к расширению: `.log` бывает и
        // дампом, а искать подстроку в бинарнике — верный способ получить
        // находку, которую невозможно показать во фрагменте.
        if data.prefix(sniffLength).contains(0) { return nil }

        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        // Windows-1251 не факультативна: русские .txt и .csv с сетевых шар
        // приходят из Windows, и без неё поиск по ним молча не находил бы
        // ничего — худший вид отказа, потому что выглядит как отсутствие
        // совпадений.
        return String(data: data, encoding: .windowsCP1251)
    }

    // MARK: - OOXML

    private static let bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")

    /// Текст документа Office.
    ///
    /// Части извлекаются в поток (`-O`), а не на диск: временная папка на
    /// каждый документ означала бы тысячи созданий и удалений каталогов за
    /// поиск, тогда как нужный XML целиком помещается в память.
    ///
    /// Шаблоны частей передаются все разом одним запуском: отсутствующие
    /// `bsdtar` пропускает молча, а запуск процесса стоит 2,5 мс — по одному на
    /// шаблон вышло бы втрое дороже на каждом файле.
    private static func ooxmlText(of url: URL, parts: [String]) async throws -> String? {
        let process = Process()
        process.executableURL = bsdtar
        // --passphrase по той же причине, что в SystemArchiveListing: без него
        // bsdtar спрашивает пароль через /dev/tty и виснет.
        process.arguments = ["-x", "-O", "--passphrase", "-", "-f", url.path] + parts

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        // Чтение канала начинается до ожидания процесса: bsdtar пишет в трубу и
        // остановится, когда её буфер заполнится, а мы будем ждать его выхода —
        // взаимная блокировка на первом же документе крупнее 64 КБ.
        async let output = Task.detached { try? stdout.fileHandleForReading.readToEnd() }.value

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }

        let data = await output ?? Data()
        let errorOutput = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()

        // Проверка отмены раньше кода возврата: убитый по SIGTERM процесс вернёт
        // ненулевой код, и без этого отмена превратилась бы в ложную ошибку.
        // Тот же порядок, что в ArchiveService и SystemArchiveListing.
        try Task.checkCancellation()

        // Ненулевой код при непустом выводе — это «часть по шаблону не нашлась»
        // (`xl/sharedStrings.xml` у таблицы без текста), а не поломка: то, что
        // нашлось, прочитано, и выбрасывать его было бы потерей находок.
        // Настоящий отказ — когда не извлечено ничего.
        guard process.terminationStatus == 0 || !data.isEmpty else {
            throw TextExtractionError.unreadableContainer(
                String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return strippingTags(String(decoding: data, as: UTF8.self))
    }

    /// Снимает XML-теги, оставляя текст между ними.
    ///
    /// Разметка не разбирается по-настоящему: нужен текст, а полноценный
    /// XML-парсер ради поиска подстроки был бы работой ради работы. Плата
    /// названа явно — прогоны текста склеиваются, и слово, у которого первая
    /// буква выделена жирным, разбито на два `<w:t>` и может не найтись.
    ///
    /// Между тегами вставляется пробел: без него текст соседних абзацев слипся
    /// бы в «концедоговора», и подстрока перестала бы находиться на границе.
    static func strippingTags(_ xml: String) -> String {
        var text = ""
        var insideTag = false
        for character in xml {
            switch character {
            case "<":
                insideTag = true
                if !text.isEmpty, text.last != " " { text.append(" ") }
            case ">":
                insideTag = false
            default:
                if !insideTag { text.append(character) }
            }
        }
        return decodingEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Пять предопределённых сущностей XML. Больше не нужно: остальное в OOXML
    /// кодируется числовыми ссылками только в экзотических случаях, а разбор
    /// всех подряд потребовал бы таблицы HTML-сущностей ради считанных знаков.
    private static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            // Амперсанд последним: иначе «&amp;lt;» превратилось бы в «<».
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - PDF

    /// Текст PDF.
    ///
    /// Отсканированные PDF без текстового слоя вернут пустоту — распознавания в
    /// проекте нет. Не ошибка: файл прочитан, текста в нём просто не оказалось.
    private static func pdfText(of url: URL) -> String? {
        PDFDocument(url: url)?.string
    }
}
