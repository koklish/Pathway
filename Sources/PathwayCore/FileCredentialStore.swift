import CryptoKit
import Foundation
import IOKit

/// Что отличает эту машину и этого пользователя от любых других.
///
/// Отдельный протокол по той же причине, что `Mounting` и `ReleaseFetching`:
/// тестам нужен предсказуемый ключ шифрования, а IOKit его не даёт — на чужой
/// машине значение другое, а в отдельных окружениях устройства нет вовсе.
public protocol MachineIdentifying: Sendable {
    var identifier: String { get }
}

/// Идентификатор платы из IOKit плюс UID пользователя.
///
/// Двух составляющих достаточно: UUID платы разделяет машины, UID — учётные
/// записи на одной машине. Домашний каталог в ключ не входит намеренно — его
/// переименование не должно обесценивать сохранённые пароли.
public struct MachineIdentity: MachineIdentifying {
    public init() {}

    public var identifier: String {
        "\(Self.platformUUID() ?? "unknown"):\(getuid())"
    }

    /// UUID материнской платы. nil в окружениях, где IOKit не отвечает.
    ///
    /// Подставлять что-то случайное вместо nil нельзя: ключ обязан быть
    /// воспроизводимым, иначе сохранённое не прочитается уже при следующем
    /// запуске. Постоянная заглушка честнее — она хотя бы работает.
    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        return IORegistryEntryCreateCFProperty(
            service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String
    }
}

/// Учётные данные в зашифрованном файле приложения.
///
/// Существует, чтобы не обращаться к Связке ключей: чтение пароля оттуда macOS
/// сопровождает диалогом подтверждения, потому что ad-hoc подпись меняется от
/// сборки к сборке и система видит другую программу при каждом обновлении.
///
/// Защита слабее, чем у Связки, и граница названа явно: файл не расшифруется на
/// другой машине и у другого пользователя системы, но расшифруется любым
/// процессом, запущенным от имени владельца. Это плата за отсутствие диалогов —
/// защита Связки от них неотделима.
public struct FileCredentialStore: CredentialStoring {
    private let fileURL: URL
    private let machine: any MachineIdentifying

    /// Путь — параметр, а не константа: иначе тесты писали бы в настоящий
    /// Application Support пользователя.
    public init(
        fileURL: URL = FileCredentialStore.defaultFileURL,
        machine: any MachineIdentifying = MachineIdentity()
    ) {
        self.fileURL = fileURL
        self.machine = machine
    }

    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Pathway", isDirectory: true)
            .appendingPathComponent("credentials.dat")
    }

    // MARK: - Чтение

    public func load(for server: ServerAddress) -> ServerCredentials? {
        readAll()[server.key].map { ServerCredentials(user: $0.user, password: $0.password) }
    }

    /// Дешёвая операция, в отличие от одноимённой у Связки ключей: файл и так
    /// читается целиком, отдельного пути «без пароля» здесь нет и не нужно.
    public func exists(for server: ServerAddress) -> Bool {
        readAll()[server.key] != nil
    }

    public func savedUser(for server: ServerAddress) -> String? {
        readAll()[server.key]?.user
    }

    // MARK: - Запись

    public func save(user: String, password: String, for server: ServerAddress) throws {
        var all = readAll()
        all[server.key] = Entry(user: user, password: password)
        try writeAll(all)
    }

    public func delete(for server: ServerAddress) throws {
        var all = readAll()
        // Записи не было — результат тот же, её нет. Переписывать файл ради
        // этого незачем.
        guard all.removeValue(forKey: server.key) != nil else { return }
        try writeAll(all)
    }

    // MARK: - Файл

    private struct Entry: Codable {
        let user: String
        let password: String
    }

    /// Нечитаемый файл равен пустому хранилищу.
    ///
    /// Ошибку здесь показать некому и незачем: у отсутствующего пароля есть
    /// корректный запасной путь — приложение спросит его у пользователя. Текст
    /// про неудавшуюся расшифровку не помог бы ничем.
    private func readAll() -> [String: Entry] {
        guard let encrypted = try? Data(contentsOf: fileURL),
              let box = try? AES.GCM.SealedBox(combined: encrypted),
              let plain = try? AES.GCM.open(box, using: key()),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: plain)
        else { return [:] }
        return decoded
    }

    private func writeAll(_ all: [String: Entry]) throws {
        // Пустое хранилище — это отсутствие файла: держать шифротекст пустого
        // словаря незачем, а его отсутствие ещё и говорит правду о содержимом.
        guard !all.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        let plain = try JSONEncoder().encode(all)
        let sealed = try AES.GCM.seal(plain, using: key())
        guard let combined = sealed.combined else {
            throw CocoaError(.fileWriteUnknown)
        }

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try combined.write(to: fileURL, options: .atomic)
        // Права ставятся после записи: .atomic пишет во временный файл и
        // переименовывает его, так что выставленные заранее не пережили бы обмен.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Ключ шифрования, выведенный из машины и пользователя.
    ///
    /// HKDF, а не PBKDF2: растягивать нечего — пароля пользователя здесь нет, а
    /// исходный материал и так не угадывается перебором. Соль — константа и
    /// секретом не является: её задача разделять контексты, а не скрывать.
    private func key() -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(machine.identifier.utf8)),
            salt: Data("pathway.credentials.v1".utf8),
            info: Data("server credentials".utf8),
            outputByteCount: 32
        )
    }
}
