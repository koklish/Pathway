import Foundation

/// Граница с системой: распаковка архива целиком.
///
/// Отдельно от `ArchiveService.extract`, потому что задачи разные: тот
/// распаковывает «умно», как Finder, — разбирается с единственным элементом
/// верхнего уровня, придумывает неконфликтующее имя, сообщает о ходе. Поиску
/// нужно ровно обратное: вывалить содержимое во временную папку как есть и
/// забыть о ней. Пропускать нужное через чужой контракт вышло бы дороже, чем
/// двадцать строк своего.
public protocol ArchiveUnpacking: Sendable {
    /// Распаковывает архив в готовую папку. Бросает, если архив нечитаем.
    func unpack(_ archive: URL, to directory: URL) async throws
}

/// Распаковка через системный `bsdtar`.
public struct SystemArchiveUnpacker: ArchiveUnpacking {
    public init() {}

    private static let bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")

    public func unpack(_ archive: URL, to directory: URL) async throws {
        let process = Process()
        process.executableURL = Self.bsdtar
        // Пароль-заглушка обязателен: без него bsdtar на зашифрованном архиве
        // спрашивает пароль через /dev/tty и виснет насмерть. Тот же приём, что
        // в SystemArchiveListing и ArchiveService.
        process.arguments = ["-x", "--passphrase", "-", "-f", archive.path, "-C", directory.path]

        let stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
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

        let errorOutput = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()

        // Проверка отмены раньше кода возврата: убитый по SIGTERM процесс вернёт
        // ненулевой код, и без этого отмена превратилась бы в ложную ошибку.
        try Task.checkCancellation()

        guard process.terminationStatus == 0 else {
            throw ArchiveListingError.toolFailed(
                String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
