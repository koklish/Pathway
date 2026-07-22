import Foundation

/// Проверяет, принимает ли хост соединения на порту.
public protocol PortProbing: Sendable {
    func isOpen(host: String, port: UInt16, timeout: TimeInterval) async -> Bool
}

/// Определяет тип сервера по тому, какие порты он слушает.
///
/// Панель хостинга даёт логин, пароль и голый IP — тип подключения там
/// написан для человека, а не для программы. Проба портов заменяет вопрос
/// «какой у вас протокол?», который пользователю задавать не хочется.
public struct ProtocolProbe: Sendable {
    private let prober: any PortProbing

    public init(prober: any PortProbing = SocketProber()) {
        self.prober = prober
    }

    /// Порты в порядке предпочтения: SMB даёт запись и список папок,
    /// FTP — только чтение, поэтому он последний.
    static let candidates: [(scheme: String, port: UInt16)] = [
        ("smb", 445),
        ("afp", 548),
        ("ftp", 21),
    ]

    /// Схема, которой отвечает хост, или nil, если не отвечает ни одна.
    public func detect(host: String, timeout: TimeInterval = 1) async -> String? {
        // Пробуем параллельно и дожидаемся всех: выбор по фиксированному
        // приоритету, а не по скорости ответа. Иначе на хосте с двумя
        // открытыми портами протокол менялся бы от запуска к запуску.
        let open = await withTaskGroup(of: (String, Bool).self) { group in
            for candidate in Self.candidates {
                group.addTask {
                    (candidate.scheme, await prober.isOpen(host: host, port: candidate.port, timeout: timeout))
                }
            }
            var result: Set<String> = []
            for await (scheme, isOpen) in group where isOpen { result.insert(scheme) }
            return result
        }

        return Self.candidates.first { open.contains($0.scheme) }?.scheme
    }
}
