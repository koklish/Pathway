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
    /// Подготовленный бандл пропал между `prepare()` и `launchInstaller()` — обычно
    /// потому, что между «Скачано» и нажатием «Перезапустить» прошли часы, и macOS
    /// успела почистить `TMPDIR`. Отдельный случай, а не `installFailed(String)`:
    /// тексту нужно не констатировать поломку, а направить к действию — заново
    /// проверить обновления, — и `restart()` в сервисе обязан отличить этот случай
    /// от прочих, чтобы не подставлять в `.failed` старый релиз для повтора
    /// загрузки (архива, на который он ссылался, тоже больше нет).
    case preparedBundleMissing

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
        case .preparedBundleMissing:
            "Подготовленное обновление больше не на месте. Проверьте обновления заново."
        }
    }
}

/// Как обновление попадает на место установленного приложения.
///
/// Два действия, а не одно, потому что между ними стоит человек. Скрипт подмены
/// отмеряет на закрытие приложения десять секунд и, не дождавшись, выходит ни с
/// чем. Пока подготовка и запуск были одним вызовом, скрипт стартовал сразу
/// после загрузки — задолго до того, как пользователь увидит кнопку
/// «Перезапустить»: он читает заметки к выпуску, дописывает письмо, уходит на
/// обед, а скрипт к этому времени давно умер, и обновление не ставилось вовсе.
/// Разделение отдаёт эти десять секунд тому, для чего они и заведены —
/// ожиданию завершения процесса, а не раздумьям человека.
public protocol UpdateInstalling: Sendable {
    /// Распаковывает архив и проверяет содержимое, возвращая путь к бандлу,
    /// готовому занять место установленного. Ничего не подменяет и не запускает.
    func prepare(archive: URL) throws -> URL

    /// Пишет скрипт-помощник и стартует его. Скрипт ждёт завершения приложения,
    /// поэтому вызывать нужно непосредственно перед `NSApp.terminate`, а не
    /// раньше: отсчёт ожидания идёт с этого момента.
    func launchInstaller(bundle: URL) throws
}

/// Закрытие приложения — граница с ОС, вынесенная в протокол по тому же
/// правилу, что `Mounting` и `TerminalRunning`.
///
/// Без неё порядок «сначала скрипт, потом terminate» проверить нечем: в тестовом
/// процессе `NSApp` не существует, и вызов уронил бы прогон на nil, а не показал
/// бы, что порядок соблюдён.
/// Протокол изолирован главным актором целиком, а не только его реализация:
/// `NSApp` главноакторный, и без изоляции на уровне протокола компилятор
/// справедливо ругается на вызов из синхронного неизолированного контекста.
/// Пометить одну лишь реализацию нельзя — она перестала бы соответствовать
/// протоколу.
@MainActor
public protocol AppTerminating: Sendable {
    func terminate()
}

/// Штатное закрытие через AppKit.
public struct AppKitTerminator: AppTerminating {
    public init() {}

    public func terminate() {
        NSApp.terminate(nil)
    }
}

/// Ставит обновление подменой бандла через внешний скрипт.
public struct BundleUpdateInstaller: UpdateInstalling {
    public init() {}

    public func prepare(archive: URL) throws -> URL {
        let unpacked = archive.deletingLastPathComponent().appendingPathComponent("unpacked")
        try? FileManager.default.removeItem(at: unpacked)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)

        // ditto, а не Archive Utility: та распространяет карантин исходного архива
        // на содержимое и портит симлинки внутри бандла.
        guard run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path]) else {
            throw UpdateError.unpackFailed
        }

        return try verifiedBundle(in: unpacked)
    }

    public func launchInstaller(bundle: URL) throws {
        // Проверка живёт здесь, а не в сервисе: между `prepare()` и нажатием
        // «Перезапустить» может пройти сколько угодно часов, и это установщик
        // отвечает за файловую систему, а не сервис состояний. Без неё скрипт
        // стартовал бы на пропавший путь: переименовал бы установленный бандл в
        // .old, ditto упал бы на несуществующий источник, сработал бы откат — и
        // человек увидел бы просто откат без объяснения причины.
        guard isValidBundle(at: bundle) else { throw UpdateError.preparedBundleMissing }
        try launchHelper(replacing: Bundle.main.bundleURL, with: bundle)
    }

    /// Не только «путь существует» — за часы простоя `TMPDIR` мог не только
    /// исчезнуть, но и превратиться во что угодно (macOS чистит по своему
    /// усмотрению, а на освободившееся место претендует кто попало). Бандл
    /// macOS — это каталог с `Info.plist` и совпадающим `CFBundleIdentifier`:
    /// то же самое условие, которым `verifiedBundle` признаёт содержимое
    /// архива годным к установке, — здесь оно же служит проверкой сохранности.
    private func isValidBundle(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }
        return Bundle(url: url)?.bundleIdentifier == Bundle.main.bundleIdentifier
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
        // Ищем бандл по совпадению идентификатора, а не первый попавшийся .app:
        // порядок contentsOfDirectory не определён, и при двух бандлах в архиве
        // выбор оказался бы случайным.
        let apps = contents.filter { $0.pathExtension == "app" }
        guard !apps.isEmpty else { throw UpdateError.notAnApp }
        guard let app = apps.first(where: {
            Bundle(url: $0)?.bundleIdentifier == Bundle.main.bundleIdentifier
        }) else {
            throw UpdateError.wrongIdentifier
        }
        guard let bundle = Bundle(url: app) else { throw UpdateError.notAnApp }

        let newVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        guard let new = newVersion.flatMap(AppVersion.init),
              let current = currentVersion.flatMap(AppVersion.init),
              new > current
        else {
            throw UpdateError.notNewer
        }

        // Это защита от битой загрузки, а не от подмены. Подпись ad-hoc, и
        // проверено: бандл с подложенным файлом, переподписанный ad-hoc заново,
        // проходит --verify --deep успешно. Подлинность держится только на HTTPS
        // к api.github.com, а не на codesign — не принимайте эту проверку за неё.
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
        // Пути приходят аргументами, а не подстановкой в текст скрипта. Интерполяция
        // даже в кавычках оставляет инъекцию: путь с кавычкой и точкой с запятой
        // закрывает строку и выполняет произвольную команду. В теле скрипта нет ни
        // одного подставленного значения — только $1 и $2, которые bash никогда не
        // разбирает как код.
        let script = """
        #!/bin/bash
        # Подменяет бандл Проводника после завершения приложения.
        # Запускается самим приложением и переживает его.
        set -u

        INSTALLED="$1"
        FRESH="$2"
        BACKUP="$1.old"

        # Ждём, пока приложение действительно закроется: замена бандла под живым
        # процессом оставила бы его в нерабочем состоянии.
        for _ in $(seq 100); do
            pgrep -x Pathway > /dev/null || break
            sleep 0.1
        done

        # Дождались не всегда: зависший процесс держит бандл, и подменять его
        # под ним — ровно та поломка, которую цикл выше должен предотвращать.
        if pgrep -x Pathway > /dev/null; then
            exit 1
        fi

        # Прежний .old обязан исчезнуть. Иначе следующий mv положит бандл ВНУТРЬ
        # уцелевшего каталога — получится Проводник.app/Проводник.app, приложение
        # мертво, а исходный бандл уже не восстановить.
        rm -rf "$BACKUP" || exit 1

        # Старый бандл переименовываем, а не удаляем: это единственная точка отката,
        # если новая версия не запустится.
        mv "$INSTALLED" "$BACKUP" || exit 1

        if ! ditto "$FRESH" "$INSTALLED"; then
            # Оборвавшийся ditto оставляет частичный каталог, и mv вложил бы
            # откат в него. Сносим остаток перед каждым восстановлением.
            rm -rf "$INSTALLED" || exit 1
            mv "$BACKUP" "$INSTALLED" || exit 1
            open "$INSTALLED"
            exit 1
        fi

        # Запоминаем PID именно нового процесса: pgrep по имени не отличил бы его
        # от прежней копии, и «приложение живо» могло бы означать вовсе не ту
        # версию. open возвращается сразу, не дожидаясь запуска, поэтому PID
        # доискиваем циклом: pgrep -n отдаёт самый новый процесс — только что
        # порождённый нами. -n у open обязателен, иначе Launch Services при живой
        # прежней копии активирует её вместо запуска новой.
        open -n -a "$INSTALLED"
        NEW_PID=""
        for _ in $(seq 100); do
            NEW_PID="$(pgrep -n -x Pathway || true)"
            [ -n "$NEW_PID" ] && break
            sleep 0.1
        done

        # Окно ожидания щедрое: первый запуск подменённого бандла с проверкой
        # Gatekeeper на медленном или сетевом диске в десять секунд не укладывается,
        # а откат по таймауту снёс бы исправно стартующее приложение.
        if [ -n "$NEW_PID" ]; then
            for _ in $(seq 600); do
                kill -0 "$NEW_PID" 2> /dev/null || break
                sleep 0.1
            done
            # Процесс прожил всё окно — обновление удалось, откат не нужен.
            if kill -0 "$NEW_PID" 2> /dev/null; then
                exit 0
            fi
        fi

        # Сюда попадаем, только если новая версия не поднялась вовсе или умерла,
        # не прожив окна: удалять установленное можно исключительно в этом случае.
        rm -rf "$INSTALLED" || exit 1
        mv "$BACKUP" "$INSTALLED" || exit 1
        open "$INSTALLED"
        # Явный ненулевой код: последней командой стоит open, и её успех иначе
        # выдал бы откат за удачное обновление.
        exit 1
        """

        let scriptURL = fresh.deletingLastPathComponent().appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, installed.path, fresh.path]
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
        let bundleURL = Bundle.main.bundleURL
        // Только /Applications: при запуске из папки сборки — штатный отладочный
        // сценарий — рядом лежит build/Проводник.app.old, и безусловная уборка
        // удаляла бы чужой каталог, к обновлению отношения не имеющий.
        guard bundleURL.deletingLastPathComponent().path == "/Applications" else { return }

        let backup = bundleURL.path + ".old"
        // Проверяем, что это каталог: одноимённый файл бандлом быть не может,
        // а значит и остатком отката — удалять его мы не подписывались.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: backup, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return }
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
