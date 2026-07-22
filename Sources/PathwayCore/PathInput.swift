import Foundation

/// Разбор пути, введённого или вставленного в адресную строку.
///
/// Кроме обычного пути принимает UNC («\\сервер\шара\папка») и smb-адрес:
/// адресная строка показывает сетевые тома именно в этом виде, поэтому
/// скопированный оттуда путь должен вставляться обратно.
public enum PathInput {
    /// Точка монтирования подключённой шары, либо nil если она не смонтирована.
    public typealias MountPointLookup = (_ host: String, _ share: String) -> URL?

    public static func resolve(
        _ input: String,
        mountPointForShare: MountPointLookup = mountedShare
    ) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Сетевой адрес разбираем отдельно и, если том не подключён, отвечаем nil.
        // Иначе «\\host\share» ушло бы в ветку обычного пути и превратилось
        // в относительный путь от рабочей папки — переход в никуда.
        if isNetworkAddress(trimmed) {
            return resolveNetwork(trimmed, mountPointForShare: mountPointForShare)
        }
        // Обычный путь: раскрываем тильду, как это делает Терминал.
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
    }

    /// Похоже ли на сетевой адрес — UNC или smb://.
    private static func isNetworkAddress(_ input: String) -> Bool {
        if input.hasPrefix(#"\\"#) { return true }
        let lowered = input.lowercased()
        return ["smb://", "cifs://", "afp://"].contains { lowered.hasPrefix($0) }
    }

    /// UNC или smb-адрес → точка монтирования, если том подключён.
    private static func resolveNetwork(
        _ input: String,
        mountPointForShare: MountPointLookup
    ) -> URL? {
        guard let (host, share, rest) = parseNetwork(input) else { return nil }
        guard let mountPoint = mountPointForShare(host, share) else { return nil }
        return rest.reduce(mountPoint) { $0.appendingPathComponent($1) }
    }

    /// Разбирает «\\host\share\a\b» и «smb://host/share/a/b» на составляющие.
    private static func parseNetwork(_ input: String) -> (host: String, share: String, rest: [String])? {
        var body: String
        if input.hasPrefix(#"\\"#) {
            body = String(input.dropFirst(2)).replacingOccurrences(of: #"\"#, with: "/")
        } else if let scheme = ["smb://", "cifs://", "afp://"].first(where: {
            input.lowercased().hasPrefix($0)
        }) {
            body = String(input.dropFirst(scheme.count))
        } else {
            return nil
        }

        let parts = body.split(separator: "/").map {
            $0.removingPercentEncoding ?? String($0)
        }
        // Нужны как минимум сервер и шара: одного имени сервера мало,
        // чтобы понять, в какой том идти.
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1], Array(parts.dropFirst(2)))
    }

    /// Ищет среди смонтированных томов тот, что отвечает этой шаре.
    public static func mountedShare(host: String, share: String) -> URL? {
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey, .volumeIsLocalKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: []
        ) ?? []

        return volumes.first { volume in
            guard let values = try? volume.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal == false,
                  let remount = values.volumeURLForRemounting,
                  let components = URLComponents(url: remount, resolvingAgainstBaseURL: false)
            else { return false }

            // Имя сервера регистронезависимо, имя шары — тоже: SMB так себя ведёт.
            let sameHost = components.host?.caseInsensitiveCompare(host) == .orderedSame
            let remoteShare = components.path.split(separator: "/").first
                .map { $0.removingPercentEncoding ?? String($0) }
            let sameShare = remoteShare?.caseInsensitiveCompare(share) == .orderedSame
            return sameHost && sameShare
        }
    }
}
