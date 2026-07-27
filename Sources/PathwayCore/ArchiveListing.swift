import Foundation

/// Граница с системой: перечисление содержимого архива.
///
/// Протокол — по общему правилу проекта о границах с ОС. Благодаря ему движок
/// поиска тестируется без единого архива на диске и без запуска процессов.
public protocol ArchiveListing: Sendable {
    /// Имена записей архива. Бросает, если архив нечитаем.
    func entryNames(of archive: URL, limit: Int) async throws -> [String]
}

extension ArchiveListing {
    func entryNames(of archive: URL) async throws -> [String] {
        try await entryNames(of: archive, limit: ZipCentralDirectory.defaultLimit)
    }
}

public enum ArchiveListingError: Error, Equatable {
    case unsupportedFormat
    case toolFailed(String)
}

/// Читает оглавление архива, выбирая способ по формату.
///
/// Единого инструмента на все форматы нет намеренно — цена разная и разница
/// измерена (см. спеку поиска):
///
/// - **ZIP** (а также .docx/.xlsx, которые тоже ZIP) читается своим парсером
///   центрального каталога: 0,03 мс против 2,5 мс на запуск процесса, и по сети
///   килобайты вместо всего архива.
/// - **RAR4, RAR5, 7z, tar.\*** — только `bsdtar`: у них оглавление размазано по
///   файлу, дешёвого пути нет ни у одного инструмента. Системный bsdtar
///   (libarchive) читает RAR обеих версий, поэтому сторонние архиваторы не
///   нужны — и хорошо, их в системе нет, а требовать установки от коллег
///   нельзя.
public struct SystemArchiveListing: ArchiveListing {
    public init() {}

    /// Расширения, читаемые своим парсером ZIP. Контейнеры OOXML и OpenDocument
    /// включены: внутри они обычный ZIP, и заглянуть в них так же дёшево.
    private static let zipExtensions: Set<String> = [
        "zip", "docx", "xlsx", "pptx", "odt", "ods", "odp", "epub", "jar", "ipa",
    ]

    public func entryNames(of archive: URL, limit: Int) async throws -> [String] {
        if Self.zipExtensions.contains(archive.pathExtension.lowercased()) {
            // Синхронно и без процесса: чтение хвоста файла стоит сотых долей
            // миллисекунды, и уход в отдельную задачу стоил бы дороже работы.
            return try ZipCentralDirectory.entryNames(of: archive, limit: limit)
        }
        return try await Self.listWithBsdtar(archive, limit: limit)
    }

    // MARK: - bsdtar

    private static let bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")

    /// Пароль-заглушка: имена файлов в архивах не шифруются, поэтому оглавление
    /// зашифрованного архива читается без пароля. Передаётся всегда — иначе
    /// bsdtar пытается спросить пароль через /dev/tty и виснет.
    private static let dummyPassphrase = "-"

    private static func listWithBsdtar(_ archive: URL, limit: Int) async throws -> [String] {
        let process = Process()
        process.executableURL = bsdtar
        process.arguments = ["-t", "--passphrase", dummyPassphrase, "-f", archive.path]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

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

        let output = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        let errorOutput = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()

        // Проверка отмены раньше кода возврата: убитый по SIGTERM процесс вернёт
        // ненулевой код, и без этого отмена превратилась бы в ложную ошибку.
        // Тот же порядок, что в ArchiveService.
        try Task.checkCancellation()

        guard process.terminationStatus == 0 else {
            throw ArchiveListingError.toolFailed(
                String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return String(decoding: output, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(limit)
            // Папки отбрасываются: в выдаче поиска они шум, пользователь ищет файл.
            .filter { !$0.hasSuffix("/") }
            .map(String.init)
    }
}
