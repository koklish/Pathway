import Foundation

/// Спрашивает у сервера список общих ресурсов.
public protocol ShareBrowsing: Sendable {
    /// Ресурсы сервера. Учётные данные необязательны: многие серверы
    /// показывают список и гостю.
    func shares(of host: String, user: String?, password: String?) throws -> [Share]
}

public struct ShareBrowseError: LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }

    public init(message: String) {
        self.message = message
    }

    /// Разбирает жалобу smbutil в понятный текст.
    public init(output: String, host: String) {
        if output.contains("No route to host") || output.contains("connection failed") {
            message = "Сервер «\(host)» недоступен. Проверьте адрес и подключение к сети."
        } else if output.contains("Authentication error") || output.contains("rejected") {
            message = "Не удалось войти на «\(host)». Проверьте имя пользователя и пароль."
        } else {
            message = "Не удалось получить список папок с «\(host)»."
        }
    }
}

/// Читает список ресурсов через системную утилиту smbutil.
public struct ShareBrowser: ShareBrowsing {
    public init() {}

    public func shares(of host: String, user: String? = nil, password: String? = nil) throws -> [Share] {
        // Гостевой режим, когда учётных данных нет: сервер обычно отдаёт список
        // даже неавторизованному, а системный диалог входа нам здесь не нужен.
        var arguments = ["view"]
        var target = "//"
        if let user, !user.isEmpty {
            target += percentEncoded(user)
            if let password, !password.isEmpty { target += ":" + percentEncoded(password) }
            target += "@"
        } else {
            arguments.append("-g")
        }
        target += host
        arguments.append(target)

        let (output, _) = try run(arguments)
        let shares = ShareList.parse(output)

        // Пустой список при жалобе утилиты — это ошибка, а не сервер без папок.
        if shares.isEmpty, output.contains("smbutil:") {
            throw ShareBrowseError(output: output, host: host)
        }
        return shares
    }

    /// В логине и пароле встречаются @ и :, а они разделители в URL.
    private func percentEncoded(_ text: String) -> String {
        let allowed = CharacterSet.urlUserAllowed.subtracting(CharacterSet(charactersIn: "@:"))
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private func run(_ arguments: [String]) throws -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        // Читаем до конца потока, иначе на длинном списке процесс упрётся в буфер.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }
}
