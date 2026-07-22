import AppKit
import Foundation

/// Почему обновление не поставилось.
public enum UpdateError: LocalizedError {
    case unpackFailed
    case notAnApp
    case wrongIdentifier
    case notNewer
    case signatureInvalid
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unpackFailed:
            "Не удалось распаковать загруженный архив."
        case .notAnApp:
            "В архиве нет приложения."
        case .wrongIdentifier:
            "Архив содержит другое приложение."
        case .notNewer:
            "Загруженная версия не новее установленной."
        case .signatureInvalid:
            "Подпись загруженного приложения повреждена."
        case .installFailed(let reason):
            "Не удалось установить обновление: \(reason)"
        }
    }
}

/// Как обновление попадает на место установленного приложения.
public protocol UpdateInstalling: Sendable {
    /// Распаковывает архив, проверяет содержимое и заменяет текущий бандл.
    /// После успешного вызова приложение завершается: подменять себя на ходу нельзя.
    func install(archive: URL) throws
}

/// Ставит обновление подменой бандла через внешний скрипт.
public struct BundleUpdateInstaller: UpdateInstalling {
    public init() {}

    public func install(archive: URL) throws {
        let unpacked = archive.deletingLastPathComponent().appendingPathComponent("unpacked")
        try? FileManager.default.removeItem(at: unpacked)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)

        // ditto, а не Archive Utility: та распространяет карантин исходного архива
        // на содержимое и портит симлинки внутри бандла.
        guard run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path]) else {
            throw UpdateError.unpackFailed
        }

        let newBundle = try verifiedBundle(in: unpacked)
        try launchHelper(replacing: Bundle.main.bundleURL, with: newBundle)
    }

    // MARK: - Проверка до подмены

    /// Убеждается, что распакованное годится в замену, и возвращает путь к бандлу.
    ///
    /// Проверки идут до подмены сознательно: подменить установленную копию
    /// непроверенным содержимым — значит сломать приложение у коллеги без пути назад.
    private func verifiedBundle(in directory: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.notAnApp
        }
        guard let bundle = Bundle(url: app) else { throw UpdateError.notAnApp }
        guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.wrongIdentifier
        }

        let newVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        guard let new = newVersion.flatMap(AppVersion.init),
              let current = currentVersion.flatMap(AppVersion.init),
              new > current
        else {
            throw UpdateError.notNewer
        }

        // Подпись ad-hoc, проверять её у Apple незачем — но целостность бандла
        // codesign подтверждает: битая загрузка сюда не пройдёт.
        guard run("/usr/bin/codesign", ["--verify", "--deep", app.path]) else {
            throw UpdateError.signatureInvalid
        }

        return app
    }

    // MARK: - Подмена

    /// Пишет скрипт-помощник и запускает его отсоединённым.
    ///
    /// Приложение не может заменить собственный бандл: оно из него выполняется.
    /// Скрипт дожидается завершения процесса и работает уже без нас.
    private func launchHelper(replacing installed: URL, with fresh: URL) throws {
        let backup = installed.path + ".old"
        let script = """
        #!/bin/bash
        # Подменяет бандл Проводника после завершения приложения.
        # Запускается самим приложением и переживает его.
        set -u

        INSTALLED="\(installed.path)"
        FRESH="\(fresh.path)"
        BACKUP="\(backup)"

        # Ждём, пока приложение действительно закроется: замена бандла под живым
        # процессом оставила бы его в нерабочем состоянии.
        for _ in $(seq 100); do
            pgrep -x Pathway > /dev/null || break
            sleep 0.1
        done

        rm -rf "$BACKUP"
        # Старый бандл переименовываем, а не удаляем: это единственная точка отката,
        # если новая версия не запустится.
        mv "$INSTALLED" "$BACKUP" || exit 1

        if ! ditto "$FRESH" "$INSTALLED"; then
            mv "$BACKUP" "$INSTALLED"
            open "$INSTALLED"
            exit 1
        fi

        open "$INSTALLED"

        # Новая версия должна подняться. Если через десять секунд её нет —
        # считаем обновление неудачным и возвращаем прежнюю.
        for _ in $(seq 100); do
            pgrep -x Pathway > /dev/null && exit 0
            sleep 0.1
        done

        rm -rf "$INSTALLED"
        mv "$BACKUP" "$INSTALLED"
        open "$INSTALLED"
        """

        let scriptURL = fresh.deletingLastPathComponent().appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        do {
            try process.run()
        } catch {
            throw UpdateError.installFailed(error.localizedDescription)
        }
    }

    // MARK: - Уборка

    /// Удаляет бандл предыдущей версии, оставленный на случай отката.
    ///
    /// Вызывается при старте: раз мы выполняемся, обновление удалось и запасная
    /// копия больше не нужна. Иначе она осталась бы в /Applications навсегда.
    public static func cleanUpAfterUpdate() {
        let backup = Bundle.main.bundleURL.path + ".old"
        guard FileManager.default.fileExists(atPath: backup) else { return }
        try? FileManager.default.removeItem(atPath: backup)
    }

    /// Запускает процесс и ждёт: вызывается из фонового Task, блокировать некого.
    private func run(_ launchPath: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
