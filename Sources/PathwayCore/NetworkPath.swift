import Foundation

/// Путь к файлу на сетевом томе в виде UNC — «\\сервер\шара\папка».
///
/// macOS монтирует сетевую шару в /Volumes и показывает локальный путь, но
/// коллегам нужен адрес, который откроется у них: в проводнике Windows и
/// корпоративных программах это UNC.
public enum NetworkPath {
    /// UNC-путь для файла на сетевом томе.
    ///
    /// - Parameters:
    ///   - url: файл или папка внутри тома.
    ///   - mountPoint: точка монтирования тома, например /Volumes/MAIN.
    ///   - remountURL: адрес тома от системы (`volumeURLForRemountingKey`),
    ///     например `smb://GUEST:@samba.ip.pro/MAIN`.
    /// - Returns: строка вида `\\samba.ip.pro\MAIN\папка`, либо nil, если
    ///   адрес неполон или файл лежит вне тома.
    public static func unc(for url: URL, mountPoint: URL, remountURL: URL?) -> String? {
        guard let remountURL,
              let components = URLComponents(url: remountURL, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty
        else { return nil }

        guard let relative = relativeComponents(of: url, under: mountPoint) else { return nil }

        // Учётные данные приходят в адресе перемонтирования (smb://GUEST:@host/…),
        // но в показанном пути им не место.
        var server = host
        if let port = components.port {
            server += ":\(port)"
        }

        // Имя шары берём из адреса, а не из имени тома: при повторном
        // монтировании macOS называет том «MAIN 1», хотя шара прежняя.
        let share = components.path
            .split(separator: "/")
            .map { $0.removingPercentEncoding ?? String($0) }

        let parts = [server] + share + relative
        return #"\\"# + parts.joined(separator: #"\"#)
    }

    /// UNC-путь для файла, если он лежит на сетевом томе.
    ///
    /// Точку монтирования и адрес спрашиваем у файловой системы, поэтому
    /// результат зависит от того, что сейчас смонтировано.
    public static func unc(for url: URL) -> String? {
        let keys: Set<URLResourceKey> = [
            .volumeIsLocalKey, .volumeURLKey, .volumeURLForRemountingKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.volumeIsLocal == false,
              let mountPoint = values.volume,
              let remountURL = values.volumeURLForRemounting
        else { return nil }

        return unc(for: url, mountPoint: mountPoint, remountURL: remountURL)
    }

    /// Путь для показа пользователю: UNC для сетевых томов, обычный — для локальных.
    public static func display(for url: URL) -> String {
        unc(for: url) ?? url.path
    }

    /// Компоненты пути внутри тома. nil — если файл лежит не в этом томе.
    private static func relativeComponents(of url: URL, under mountPoint: URL) -> [String]? {
        let target = url.standardizedFileURL.pathComponents
        let root = mountPoint.standardizedFileURL.pathComponents
        // Сравниваем именно компоненты: префикс строки считал бы «/Volumes/MAIN2»
        // вложенным в «/Volumes/MAIN».
        guard target.count >= root.count, Array(target.prefix(root.count)) == root else { return nil }
        return Array(target.dropFirst(root.count))
    }
}
