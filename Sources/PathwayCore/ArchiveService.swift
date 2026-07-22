import Foundation
import Synchronization

/// Форматы, в которые Pathway умеет архивировать.
public enum ArchiveFormat: String, CaseIterable, Sendable {
    case zip
    case tarGz
    case tarBz2
    case tarXz

    public var fileExtension: String {
        switch self {
        case .zip: "zip"
        case .tarGz: "tar.gz"
        case .tarBz2: "tar.bz2"
        case .tarXz: "tar.xz"
        }
    }

    public var displayName: String {
        switch self {
        case .zip: "ZIP"
        case .tarGz: "tar.gz"
        case .tarBz2: "tar.bz2"
        case .tarXz: "tar.xz"
        }
    }

    /// Пароль поддерживает только zip (шифрование ZipCrypto).
    public var supportsPassword: Bool { self == .zip }
}

public enum ArchiveError: Error, Equatable {
    /// Архив зашифрован, а пароль не передан.
    case passwordRequired
    case wrongPassword
    /// Зашифрованные 7z/RAR системный bsdtar не распаковывает.
    case encryptedUnsupported
    case toolFailed(String)
}

/// Создание и распаковка архивов системными инструментами (zip, bsdtar).
public struct ArchiveService: Sendable {

    /// Расширения, которые открываются как архивы (двойное расширение .tar.* учитывается отдельно).
    private static let archiveExtensions: Set<String> = [
        "zip", "tar", "tgz", "tbz", "tbz2", "txz", "7z", "rar",
    ]
    private static let tarSuffixes = ["tar.gz", "tar.bz2", "tar.xz"]

    private var fm: FileManager { .default }

    public init() {}

    public static func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if archiveExtensions.contains(url.pathExtension.lowercased()) { return true }
        return tarSuffixes.contains { name.hasSuffix(".\($0)") }
    }

    // MARK: - Создание

    /// Архивирует элементы в `directory`, возвращает URL созданного архива.
    /// Все элементы должны лежать в одной папке — в архив попадают относительные пути.
    public func create(
        items: [URL],
        format: ArchiveFormat,
        password: String?,
        archiveName: String,
        in directory: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let archive = Self.uniqueURL(in: directory, base: archiveName, extension: format.fileExtension)
        let names = items.map(\.lastPathComponent)
        let total = totalEntries(of: items)

        let tool: URL
        var args: [String]
        switch format {
        case .zip:
            tool = URL(fileURLWithPath: "/usr/bin/zip")
            args = ["-r", "-y"]
            if let password, !password.isEmpty { args += ["-P", password] }
            args += [archive.path] + names
        case .tarGz, .tarBz2, .tarXz:
            tool = URL(fileURLWithPath: "/usr/bin/bsdtar")
            args = ["-c", "-v", "-a", "-f", archive.path] + names
        }

        do {
            try await Self.run(tool, args, workingDirectory: directory) { lineCount in
                progress?(min(1, Double(lineCount) / Double(max(1, total))))
            }
        } catch {
            try? fm.removeItem(at: archive)
            throw error
        }
        return archive
    }

    // MARK: - Распаковка

    /// Распаковывает архив в `directory` «умно», как Finder: единственный элемент
    /// верхнего уровня извлекается как есть, иначе создаётся папка с именем архива.
    /// Возвращает URL извлечённого элемента.
    public func extract(
        archive: URL,
        to directory: URL,
        password: String?,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let total = try await listEntryCount(of: archive, password: password)

        let temp = directory.appendingPathComponent(".pathway-extract-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        // Пароль передаётся всегда (при отсутствии — заглушка), иначе bsdtar
        // пытается интерактивно спросить его через /dev/tty.
        let args = ["-x", "-v", "--passphrase", password ?? Self.dummyPassphrase,
                    "-f", archive.path, "-C", temp.path]
        do {
            try await Self.run(bsdtar, args, workingDirectory: directory) { lineCount in
                progress?(min(1, Double(lineCount) / Double(max(1, total))))
            }
        } catch ArchiveError.wrongPassword where password == nil {
            throw ArchiveError.passwordRequired
        }

        let extracted = try fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)
        if extracted.count == 1, let single = extracted.first {
            let target = Self.uniqueURL(in: directory, base: Self.splitName(single.lastPathComponent).base,
                                        extension: Self.splitName(single.lastPathComponent).ext)
            try fm.moveItem(at: single, to: target)
            return target
        }
        let wrapper = Self.uniqueURL(in: directory, base: Self.archiveBaseName(archive), extension: "")
        try fm.createDirectory(at: wrapper, withIntermediateDirectories: false)
        for item in extracted {
            try fm.moveItem(at: item, to: wrapper.appendingPathComponent(item.lastPathComponent))
        }
        return wrapper
    }

    // MARK: - Вспомогательное

    private let bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")

    /// Пароль-заглушка: имена файлов в архивах не шифруются, поэтому листинг
    /// и распаковка незашифрованных архивов с ней работают как обычно.
    private static let dummyPassphrase = "-"

    /// Число записей в архиве — знаменатель для прогресса распаковки.
    private func listEntryCount(of archive: URL, password: String?) async throws -> Int {
        let args = ["-t", "--passphrase", password ?? Self.dummyPassphrase, "-f", archive.path]
        let count = Mutex(0)
        try await Self.run(bsdtar, args, workingDirectory: nil) { lineCount in
            count.withLock { $0 = lineCount }
        }
        return count.withLock { $0 }
    }

    /// Число файлов и папок внутри элементов — знаменатель для прогресса архивации.
    private func totalEntries(of items: [URL]) -> Int {
        var count = 0
        for item in items {
            count += 1
            if let enumerator = fm.enumerator(at: item, includingPropertiesForKeys: nil) {
                count += enumerator.allObjects.count
            }
        }
        return count
    }

    /// Имя архива без архивного расширения: «Пара.zip» → «Пара», «x.tar.gz» → «x».
    static func archiveBaseName(_ archive: URL) -> String {
        let name = archive.lastPathComponent
        let lowered = name.lowercased()
        for suffix in tarSuffixes where lowered.hasSuffix(".\(suffix)") {
            return String(name.dropLast(suffix.count + 1))
        }
        return archive.deletingPathExtension().lastPathComponent
    }

    private static func splitName(_ name: String) -> (base: String, ext: String) {
        let url = URL(fileURLWithPath: "/\(name)")
        let ext = url.pathExtension
        return ext.isEmpty ? (name, "") : (url.deletingPathExtension().lastPathComponent, ext)
    }

    /// Подбирает свободное имя: «Архив.zip», «Архив 2.zip», «Материалы 2»…
    private static func uniqueURL(in directory: URL, base: String, extension ext: String) -> URL {
        func url(for candidate: String) -> URL {
            let name = ext.isEmpty ? candidate : "\(candidate).\(ext)"
            return directory.appendingPathComponent(name)
        }
        var candidate = base
        var index = 2
        while FileManager.default.fileExists(atPath: url(for: candidate).path) {
            candidate = "\(base) \(index)"
            index += 1
        }
        return url(for: candidate)
    }

    // MARK: - Запуск процессов

    /// Запускает инструмент, стримит число строк вывода в `onLines`, по завершении
    /// с ненулевым кодом бросает `ArchiveError`, сопоставленный по stderr.
    private static func run(
        _ tool: URL,
        _ arguments: [String],
        workingDirectory: URL?,
        onLines: @escaping @Sendable (Int) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        let counter = LineCounter(onLines: onLines)
        stdout.fileHandleForReading.readabilityHandler = { counter.consume($0.availableData, isError: false) }
        stderr.fileHandleForReading.readabilityHandler = { counter.consume($0.availableData, isError: true) }

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

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        counter.consume(try stdout.fileHandleForReading.readToEnd() ?? Data(), isError: false)
        counter.consume(try stderr.fileHandleForReading.readToEnd() ?? Data(), isError: true)

        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            throw Self.mapError(stderr: counter.errorText)
        }
    }

    private static func mapError(stderr: String) -> ArchiveError {
        let text = stderr.lowercased()
        if text.contains("incorrect passphrase") { return .wrongPassword }
        if text.contains("passphrase required") { return .passwordRequired }
        if text.contains("encrypted") && text.contains("unsupported") { return .encryptedUnsupported }
        return .toolFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Считает строки вывода процесса и копит stderr для сообщений об ошибках.
private final class LineCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var lines = 0
    private var stderrData = Data()
    private let onLines: @Sendable (Int) -> Void

    init(onLines: @escaping @Sendable (Int) -> Void) {
        self.onLines = onLines
    }

    func consume(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if isError { stderrData.append(data) }
        lines += data.count(where: { $0 == UInt8(ascii: "\n") })
        let current = lines
        lock.unlock()
        onLines(current)
    }

    var errorText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stderrData, as: UTF8.self)
    }
}
