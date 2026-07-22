# Самообновление через GitHub Releases — план реализации

> **Для агентов:** ОБЯЗАТЕЛЬНАЯ ПОД-СКИЛЛ: используйте superpowers:subagent-driven-development
> (рекомендуется) или superpowers:executing-plans для выполнения задача за задачей. Шаги отмечены
> чекбоксами (`- [ ]`).

**Цель:** приложение само замечает вышедший на GitHub релиз, показывает это значком в правом углу
строки заголовка и по нажатию обновляется целиком — скачивает, подменяет бандл, перезапускается.

**Архитектура:** вся логика в `PathwayCore` за протоколами `ReleaseFetching` и `UpdateInstalling` —
Core тестируется без сети и без доступа к `/Applications`. Подмену бандла делает внешний
скрипт-помощник: приложение не может заменить себя на ходу. Откат живёт в том же скрипте — старый
бандл переименовывается, а не удаляется.

**Технологии:** Swift 6, SwiftUI + AppKit, swift-testing, `URLSession`, `ditto`, `gh` CLI.

**Спека:** `docs/superpowers/specs/2026-07-22-auto-update-design.md`

## Общие ограничения

- Весь код, комментарии, тесты и сообщения коммитов — **на русском**.
- Тестами покрывается **только `PathwayCore`**. UI-тестов в проекте нет принципиально.
- `@Suite("Русское описание")` на `struct` с английским именем, `@Test("русская фраза")` на функциях
  с английскими именами. `--filter` работает только по английским именам.
- SwiftUI в `PathwayCore` не импортируется нигде.
- **Никогда не добавлять `LSFileQuarantineEnabled` в `Resources/Info.plist`** — это сломает
  обновление целиком (Gatekeeper начнёт проверять ad-hoc подпись скачанного бандла).
- Репозиторий обновлений: `koklish/Pathway`, адрес API —
  `https://api.github.com/repos/koklish/Pathway/releases/latest`.
- Идентификатор бандла `com.pathway.filemanager` не менять: к нему привязаны пароли в Связке ключей.
- **Не пушить в origin и не создавать релизы.** Это делает пользователь сам.
- Комментарии объясняют «почему», а не «что», с явным «иначе …» / «а не …».
- Один смысловой шаг — один коммит. Заголовок — именная группа на русском, без префиксов `feat:`/`fix:`.

## Структура файлов

| Файл | Ответственность |
|---|---|
| `Sources/PathwayCore/AppVersion.swift` | Разбор и сравнение версий. Чистое значение, ничего не знает о сети |
| `Sources/PathwayCore/ReleaseInfo.swift` | Описание релиза + протокол `ReleaseFetching` + боевая реализация для GitHub |
| `Sources/PathwayCore/UpdateInstaller.swift` | Протокол `UpdateInstalling` + боевая реализация: распаковка, проверка, скрипт-помощник |
| `Sources/PathwayCore/UpdateService.swift` | Состояние и оркестровка: когда проверять, что показывать |
| `Sources/Pathway/UpdateBadgeView.swift` | Значок в строке заголовка |
| `Tests/PathwayCoreTests/AppVersionTests.swift` | Сравнение версий |
| `Tests/PathwayCoreTests/UpdateServiceTests.swift` | Фиктивные реализации + поведение сервиса |
| `release.sh` | Выпуск релиза одной командой |

Разделение по ответственности, а не «всё в один `UpdateService.swift`»: `AppVersion` тестируется
изолированно, `ReleaseInfo` и `UpdateInstaller` — две разные границы с системой (сеть и файловая
система), сервис не должен знать деталей ни одной из них.

---

### Задача 1: Разбор и сравнение версий

**Файлы:**
- Создать: `Sources/PathwayCore/AppVersion.swift`
- Тест: `Tests/PathwayCoreTests/AppVersionTests.swift`

**Интерфейсы:**
- Использует: ничего
- Даёт: `AppVersion` — `init?(_ string: String)`, `Comparable`, `CustomStringConvertible`,
  свойство `components: [Int]`. Дальше используется в `ReleaseInfo` и `UpdateService`.

- [ ] **Шаг 1: Пишем падающий тест**

Создать `Tests/PathwayCoreTests/AppVersionTests.swift`:

```swift
import Testing

@testable import PathwayCore

@Suite("Версия приложения")
struct AppVersionTests {
    @Test("сравнивает по числам, а не по строкам")
    func comparesNumerically() {
        // Строковое сравнение дало бы «1.10.0 < 1.9.0» — самая частая ошибка
        // самодельных апдейтеров: после 1.9 обновления просто перестают приходить.
        #expect(AppVersion("1.10.0")! > AppVersion("1.9.0")!)
        #expect(AppVersion("2.0.0")! > AppVersion("1.99.99")!)
    }

    @Test("одинаковые версии равны")
    func equalVersions() {
        #expect(AppVersion("1.2.3")! == AppVersion("1.2.3")!)
    }

    @Test("разбирает тег с префиксом v")
    func stripsTagPrefix() {
        #expect(AppVersion("v1.2.3")! == AppVersion("1.2.3")!)
    }

    @Test("недостающие компоненты считаются нулями")
    func missingComponentsAreZero() {
        #expect(AppVersion("1.2")! == AppVersion("1.2.0")!)
        #expect(AppVersion("1")! < AppVersion("1.0.1")!)
    }

    @Test("отвергает строку без чисел")
    func rejectsGarbage() {
        #expect(AppVersion("") == nil)
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("v") == nil)
    }

    @Test("показывается в исходном виде")
    func description() {
        #expect(AppVersion("1.2.3")!.description == "1.2.3")
        #expect(AppVersion("v1.2.3")!.description == "1.2.3")
    }
}
```

- [ ] **Шаг 2: Запускаем — тест должен упасть**

Выполнить: `swift test --filter AppVersionTests`
Ожидается: ошибка компиляции «cannot find 'AppVersion' in scope».

- [ ] **Шаг 3: Пишем минимальную реализацию**

Создать `Sources/PathwayCore/AppVersion.swift`:

```swift
import Foundation

/// Версия приложения вида `1.2.3`.
///
/// Сравнивается почисленно по компонентам, а не как строка: строковое сравнение
/// поставило бы «1.10.0» перед «1.9.0», и после версии 1.9 обновления перестали
/// бы приходить вовсе.
public struct AppVersion: Sendable, Comparable, CustomStringConvertible {
    public let components: [Int]

    /// Разбирает `1.2.3` или тег `v1.2.3`. Возвращает nil, если чисел нет вовсе.
    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        // Тег релиза на GitHub принято писать с «v», а CFBundleShortVersionString — без.
        let digits = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var parsed: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0 else { return nil }
            parsed.append(number)
        }
        components = parsed
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        // Недостающие компоненты — нули: «1.2» и «1.2.0» это одна версия.
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }
}
```

- [ ] **Шаг 4: Запускаем — тесты должны пройти**

Выполнить: `swift test --filter AppVersionTests`
Ожидается: 6 тестов пройдено.

- [ ] **Шаг 5: Коммит**

```bash
git add Sources/PathwayCore/AppVersion.swift Tests/PathwayCoreTests/AppVersionTests.swift
git commit -m "Core: разбор и сравнение версий приложения

Сравнение почисленно по компонентам: строковое поставило бы 1.10.0 перед
1.9.0, и после версии 1.9 обновления перестали бы приходить. Недостающие
компоненты считаются нулями, префикс v из тега GitHub отбрасывается."
```

---

### Задача 2: Описание релиза и загрузка с GitHub

**Файлы:**
- Создать: `Sources/PathwayCore/ReleaseInfo.swift`
- Тест: покрывается в задаче 4 (здесь только разбор JSON, он проверяется через сервис)

**Интерфейсы:**
- Использует: `AppVersion` из задачи 1
- Даёт: `ReleaseInfo` (поля `version: AppVersion`, `archiveURL: URL`, `notes: String`,
  `size: Int64`), протокол `ReleaseFetching` с методом
  `func latestRelease() async throws -> ReleaseInfo?`, и `GitHubReleaseFetcher()`.
  Возврат `nil` означает «релизов нет или без ZIP-ассета» — это не ошибка.

- [ ] **Шаг 1: Пишем реализацию**

Тест на разбор JSON поставим в задаче 4 вместе с фиктивным загрузчиком: здесь нет ничего, что
можно проверить, не выходя в сеть.

Создать `Sources/PathwayCore/ReleaseInfo.swift`:

```swift
import Foundation

/// Вышедший релиз на GitHub.
public struct ReleaseInfo: Sendable, Equatable {
    public let version: AppVersion
    /// Прямая ссылка на ZIP с бандлом.
    public let archiveURL: URL
    /// Заметки к выпуску — показываются в поповере значка.
    public let notes: String
    public let size: Int64

    public init(version: AppVersion, archiveURL: URL, notes: String, size: Int64) {
        self.version = version
        self.archiveURL = archiveURL
        self.notes = notes
        self.size = size
    }
}

/// Где приложение узнаёт о новых версиях.
///
/// Протокол, а не прямой вызов сети: иначе тесты сервиса ходили бы на GitHub —
/// медленно, ненадёжно и с оглядкой на лимит запросов.
public protocol ReleaseFetching: Sendable {
    /// Последний релиз, либо nil, если релизов нет или к ним не приложен ZIP.
    func latestRelease() async throws -> ReleaseInfo?
}

/// Спрашивает GitHub о последнем релизе.
public struct GitHubReleaseFetcher: ReleaseFetching {
    private let endpoint: URL
    private let session: URLSession

    /// Репозиторий публичный, поэтому запрос идёт без авторизации: токен в
    /// раздаваемом коллегам бинарнике всё равно что опубликован.
    public init(
        repository: String = "koklish/Pathway",
        session: URLSession = .shared
    ) {
        endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        self.session = session
    }

    public func latestRelease() async throws -> ReleaseInfo? {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Без User-Agent GitHub отвечает 403 — требование их API, не наша прихоть.
        request.setValue("Pathway", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        // 404 — релизов ещё нет: это нормальное состояние свежего репозитория,
        // а не ошибка, о которой стоит говорить пользователю.
        guard http.statusCode == 200 else { return nil }

        return Self.parse(data)
    }

    /// Разбирает ответ GitHub. Отделено от запроса, чтобы проверять без сети.
    static func parse(_ data: Data) -> ReleaseInfo? {
        struct Payload: Decodable {
            let tagName: String
            let body: String?
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]

            struct Asset: Decodable {
                let name: String
                let browserDownloadURL: URL
                let size: Int64
            }
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return nil }
        // Черновики и предрелизы коллегам не раздаём: их видно только владельцу
        // репозитория, и обновляться на них никто не просил.
        guard !payload.draft, !payload.prerelease else { return nil }
        guard let version = AppVersion(payload.tagName) else { return nil }
        // Релиз без приложенного ZIP обновить нечем — ведём себя как будто его нет.
        guard let asset = payload.assets.first(where: { $0.name.hasSuffix(".zip") }) else { return nil }

        return ReleaseInfo(
            version: version,
            archiveURL: asset.browserDownloadURL,
            notes: payload.body ?? "",
            size: asset.size
        )
    }
}
```

- [ ] **Шаг 2: Проверяем сборку**

Выполнить: `swift build`
Ожидается: сборка без ошибок.

- [ ] **Шаг 3: Коммит**

```bash
git add Sources/PathwayCore/ReleaseInfo.swift
git commit -m "Core: описание релиза и запрос к GitHub

Протокол ReleaseFetching отделяет сервис от сети — иначе его тесты ходили бы
на GitHub, упираясь в лимит запросов. Разбор ответа вынесен в статическую
parse и проверяется без сети.

Черновики, предрелизы и релизы без ZIP-ассета считаются отсутствующими:
обновляться на них нечем. Ответ 404 тоже не ошибка — так выглядит репозиторий,
где релизов ещё не выкладывали."
```

---

### Задача 3: Установщик — распаковка, проверка, скрипт-помощник

**Файлы:**
- Создать: `Sources/PathwayCore/UpdateInstaller.swift`
- Тест: покрытие ручное (чек-лист спеки) — настоящая реализация трогает `/Applications`

**Интерфейсы:**
- Использует: `AppVersion` из задачи 1
- Даёт: протокол `UpdateInstalling` с методом `func install(archive: URL) throws`,
  `BundleUpdateInstaller()`, `enum UpdateError: LocalizedError`, и статический метод
  `BundleUpdateInstaller.cleanUpAfterUpdate()` — вызывается при старте приложения.

- [ ] **Шаг 1: Пишем реализацию**

Создать `Sources/PathwayCore/UpdateInstaller.swift`:

```swift
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
```

- [ ] **Шаг 2: Проверяем сборку**

Выполнить: `swift build`
Ожидается: сборка без ошибок.

- [ ] **Шаг 3: Коммит**

```bash
git add Sources/PathwayCore/UpdateInstaller.swift
git commit -m "Core: установка обновления подменой бандла

Приложение не может заменить собственный бандл — оно из него выполняется,
поэтому подмену делает внешний скрипт, дожидающийся завершения процесса.
Он же держит откат: старый бандл переименовывается в .old, а не удаляется,
и возвращается на место, если новая версия не поднялась за десять секунд.
Схема переживает и битую загрузку, и падение новой версии на старте.

Распаковка через ditto, а не Archive Utility: та распространяет карантин
исходного архива на содержимое и портит симлинки внутри бандла.

Всё, что можно проверить, проверяется до подмены: идентификатор бандла,
версия новее текущей, целостность подписи. Подменять установленную копию
непроверенным содержимым — значит сломать приложение у коллеги без пути назад."
```

---

### Задача 4: Сервис обновлений

**Файлы:**
- Создать: `Sources/PathwayCore/UpdateService.swift`
- Тест: `Tests/PathwayCoreTests/UpdateServiceTests.swift`

**Интерфейсы:**
- Использует: `AppVersion` (задача 1), `ReleaseInfo`/`ReleaseFetching` (задача 2),
  `UpdateInstalling`/`UpdateError` (задача 3)
- Даёт: `UpdateState` (перечисление), `UpdateService` с
  `init(currentVersion:fetcher:installer:defaults:session:)`,
  свойствами `state`, `currentVersion` и методами
  `checkAutomatically()`, `checkManually()`, `download()`, `restart()`.

- [ ] **Шаг 1: Пишем падающий тест**

Создать `Tests/PathwayCoreTests/UpdateServiceTests.swift`:

```swift
import Foundation
import Testing

@testable import PathwayCore

/// Подменяет GitHub: отдаёт заданный релиз и считает обращения.
final class FakeReleaseFetcher: ReleaseFetching, @unchecked Sendable {
    var release: ReleaseInfo?
    var error: (any Error)?
    private(set) var callCount = 0

    init(release: ReleaseInfo? = nil, error: (any Error)? = nil) {
        self.release = release
        self.error = error
    }

    func latestRelease() async throws -> ReleaseInfo? {
        callCount += 1
        if let error { throw error }
        return release
    }
}

/// Подменяет установщик: настоящий трогает /Applications.
final class FakeInstaller: UpdateInstalling, @unchecked Sendable {
    private(set) var installed: URL?
    var error: (any Error)?

    func install(archive: URL) throws {
        if let error { throw error }
        installed = archive
    }
}

private func makeRelease(_ version: String) -> ReleaseInfo {
    ReleaseInfo(
        version: AppVersion(version)!,
        archiveURL: URL(string: "https://example.com/Проводник.zip")!,
        notes: "Что нового",
        size: 1024
    )
}

@Suite("Сервис обновлений")
struct UpdateServiceTests {
    /// Свежий suiteName на каждый тест: иначе дата последней проверки протекала бы
    /// между тестами и ограничение суток срабатывало бы непредсказуемо.
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "update-tests-\(UUID().uuidString)")!
    }

    @MainActor
    private func makeService(
        current: String = "1.0.0",
        fetcher: FakeReleaseFetcher,
        installer: FakeInstaller = FakeInstaller(),
        defaults: UserDefaults? = nil
    ) -> UpdateService {
        UpdateService(
            currentVersion: AppVersion(current)!,
            fetcher: fetcher,
            installer: installer,
            defaults: defaults ?? makeDefaults()
        )
    }

    @Test("замечает релиз новее установленного")
    @MainActor
    func findsNewerRelease() async {
        let fetcher = FakeReleaseFetcher(release: makeRelease("1.1.0"))
        let service = makeService(fetcher: fetcher)

        await service.checkManually()

        #expect(service.state == .available(makeRelease("1.1.0")))
    }

    @Test("не предлагает обновиться на ту же версию")
    @MainActor
    func ignoresSameVersion() async {
        let service = makeService(fetcher: FakeReleaseFetcher(release: makeRelease("1.0.0")))

        await service.checkManually()

        #expect(service.state == .idle)
    }

    @Test("не предлагает откатиться на старую версию")
    @MainActor
    func ignoresOlderRelease() async {
        let service = makeService(fetcher: FakeReleaseFetcher(release: makeRelease("0.9.0")))

        await service.checkManually()

        #expect(service.state == .idle)
    }

    @Test("молчит, когда автопроверка не удалась")
    @MainActor
    func automaticFailureIsSilent() async {
        // Приложение в дороге без интернета не должно ругаться при каждом запуске.
        let fetcher = FakeReleaseFetcher(error: URLError(.notConnectedToInternet))
        let service = makeService(fetcher: fetcher)

        await service.checkAutomatically()

        #expect(service.state == .idle)
    }

    @Test("показывает ошибку, когда проверку запросил пользователь")
    @MainActor
    func manualFailureIsVisible() async {
        let fetcher = FakeReleaseFetcher(error: URLError(.notConnectedToInternet))
        let service = makeService(fetcher: fetcher)

        await service.checkManually()

        guard case .failed = service.state else {
            Issue.record("ожидалось состояние .failed, получено \(service.state)")
            return
        }
    }

    @Test("вторая автопроверка за сутки не идёт в сеть")
    @MainActor
    func automaticCheckIsThrottled() async {
        let fetcher = FakeReleaseFetcher(release: makeRelease("1.1.0"))
        let defaults = makeDefaults()
        let service = makeService(fetcher: fetcher, defaults: defaults)

        await service.checkAutomatically()
        await service.checkAutomatically()

        #expect(fetcher.callCount == 1)
    }

    @Test("ручная проверка ограничение суток не соблюдает")
    @MainActor
    func manualCheckIgnoresThrottle() async {
        let fetcher = FakeReleaseFetcher(release: makeRelease("1.1.0"))
        let defaults = makeDefaults()
        let service = makeService(fetcher: fetcher, defaults: defaults)

        await service.checkAutomatically()
        await service.checkManually()

        #expect(fetcher.callCount == 2)
    }

    @Test("отсутствие релизов не считается ошибкой")
    @MainActor
    func noReleasesIsNotAnError() async {
        let service = makeService(fetcher: FakeReleaseFetcher(release: nil))

        await service.checkManually()

        #expect(service.state == .idle)
    }

    @Test("разбирает ответ GitHub")
    func parsesGitHubPayload() throws {
        let json = """
        {
          "tag_name": "v1.5.0",
          "body": "Исправлены ошибки",
          "draft": false,
          "prerelease": false,
          "assets": [
            {"name": "Проводник.zip",
             "browser_download_url": "https://example.com/a.zip",
             "size": 2048}
          ]
        }
        """.data(using: .utf8)!

        let release = try GitHubReleaseFetcher.parse(json)

        #expect(release?.version == AppVersion("1.5.0")!)
        #expect(release?.size == 2048)
        #expect(release?.notes == "Исправлены ошибки")
    }

    @Test("пропускает предрелиз")
    func skipsPrerelease() throws {
        let json = """
        {
          "tag_name": "v2.0.0", "body": "", "draft": false, "prerelease": true,
          "assets": [{"name": "a.zip", "browser_download_url": "https://e.com/a.zip", "size": 1}]
        }
        """.data(using: .utf8)!

        #expect(try GitHubReleaseFetcher.parse(json) == nil)
    }

    @Test("пропускает релиз без архива")
    func skipsReleaseWithoutArchive() throws {
        // Обновляться нечем — ведём себя так, будто релиза нет.
        let json = """
        {"tag_name": "v2.0.0", "body": "", "draft": false, "prerelease": false, "assets": []}
        """.data(using: .utf8)!

        #expect(try GitHubReleaseFetcher.parse(json) == nil)
    }
}
```

- [ ] **Шаг 2: Запускаем — тесты должны упасть**

Выполнить: `swift test --filter UpdateServiceTests`
Ожидается: ошибка компиляции «cannot find 'UpdateService' in scope».

- [ ] **Шаг 3: Пишем реализацию**

Создать `Sources/PathwayCore/UpdateService.swift`:

```swift
import AppKit
import Foundation
import Observation

/// Что показывает значок в строке заголовка.
public enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case available(ReleaseInfo)
    case downloading(Double)
    case readyToRestart
    case failed(String)
}

/// Проверка и установка обновлений.
///
/// Знает, когда стоит спрашивать GitHub и что показать пользователю; как именно
/// добывается релиз и как он ставится — дело ReleaseFetching и UpdateInstalling.
@Observable
@MainActor
public final class UpdateService {
    public private(set) var state: UpdateState = .idle
    public let currentVersion: AppVersion

    private let fetcher: any ReleaseFetching
    private let installer: any UpdateInstalling
    private let defaults: UserDefaults
    private let session: URLSession

    private static let lastCheckKey = "lastUpdateCheck"
    /// Реже суток проверять незачем, чаще — незачем тем более: лимит GitHub без
    /// авторизации 60 запросов в час на адрес, и все коллеги могут сидеть за одним NAT.
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    public init(
        currentVersion: AppVersion? = nil,
        fetcher: any ReleaseFetching = GitHubReleaseFetcher(),
        installer: any UpdateInstalling = BundleUpdateInstaller(),
        defaults: UserDefaults = .standard,
        session: URLSession = .shared
    ) {
        let bundled = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        self.currentVersion = currentVersion ?? bundled.flatMap(AppVersion.init) ?? AppVersion("0.0.0")!
        self.fetcher = fetcher
        self.installer = installer
        self.defaults = defaults
        self.session = session
    }

    // MARK: - Проверка

    /// Проверка при запуске и раз в сутки. Неудача остаётся незамеченной.
    public func checkAutomatically() async {
        guard shouldCheckNow else { return }
        await check(silent: true)
    }

    /// Проверка по просьбе пользователя: игнорирует ограничение и показывает ошибку.
    public func checkManually() async {
        await check(silent: false)
    }

    private var shouldCheckNow: Bool {
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date
        guard let last else { return true }
        return Date().timeIntervalSince(last) >= Self.checkInterval
    }

    private func check(silent: Bool) async {
        // Пока идёт скачивание, проверять нечего — иначе состояние перетрётся.
        if case .downloading = state { return }
        if case .readyToRestart = state { return }

        state = .checking
        defaults.set(Date(), forKey: Self.lastCheckKey)

        do {
            let release = try await fetcher.latestRelease()
            guard let release, release.version > currentVersion else {
                state = .idle
                return
            }
            state = .available(release)
        } catch {
            // Нет сети — обычное дело, и само по себе не повод беспокоить человека.
            // Сказать стоит только тому, кто проверку и запросил.
            state = silent ? .idle : .failed(error.localizedDescription)
        }
    }

    // MARK: - Загрузка и установка

    /// Скачивает обновление и готовит подмену бандла.
    public func download() async {
        guard case .available(let release) = state else { return }
        state = .downloading(0)

        do {
            let archive = try await downloadArchive(release)
            try installer.install(archive: archive)
            state = .readyToRestart
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func downloadArchive(_ release: ReleaseInfo) async throws -> URL {
        let (bytes, response) = try await session.bytes(from: release.archiveURL)
        let expected = response.expectedContentLength > 0
            ? response.expectedContentLength : release.size

        var data = Data()
        data.reserveCapacity(Int(expected))
        var lastShown = 0.0
        for try await byte in bytes {
            data.append(byte)
            let progress = Double(data.count) / Double(expected)
            // Перерисовывать значок на каждый байт незачем: шаг в процент незаметен
            // глазу, а обновление @Observable на каждой итерации стоит дорого.
            if progress - lastShown >= 0.01 {
                lastShown = progress
                state = .downloading(min(progress, 1))
            }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathwayUpdate", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let archive = directory.appendingPathComponent("update.zip")
        try data.write(to: archive)
        return archive
    }

    /// Закрывает приложение — дальше работает скрипт-помощник.
    public func restart() {
        NSApp.terminate(nil)
    }
}
```

- [ ] **Шаг 4: Запускаем — тесты должны пройти**

Выполнить: `swift test --filter UpdateServiceTests`
Ожидается: 11 тестов пройдено.

- [ ] **Шаг 5: Прогоняем всё, чтобы ничего не сломалось**

Выполнить: `swift test`
Ожидается: все тесты проходят (было ~255, стало ~272).

- [ ] **Шаг 6: Коммит**

```bash
git add Sources/PathwayCore/UpdateService.swift Tests/PathwayCoreTests/UpdateServiceTests.swift
git commit -m "Core: сервис обновлений с проверкой раз в сутки

Автопроверка молчит при неудаче, ручная показывает ошибку: приложение в
дороге без интернета не должно ругаться при каждом запуске, но человек,
нажавший «Проверить обновления», ответа ждёт.

Ограничение раза в сутки держится на дате в UserDefaults и обходится ручной
проверкой. Лимит GitHub без авторизации — 60 запросов в час на адрес, и все
коллеги могут сидеть за одним NAT.

Прогресс загрузки обновляется шагом в процент, а не на каждый байт: разницы
на глаз нет, а запись в @Observable на каждой итерации стоит дорого."
```

---

### Задача 5: Значок в строке заголовка

**Файлы:**
- Создать: `Sources/Pathway/UpdateBadgeView.swift`
- Изменить: `Sources/Pathway/PathwayApp.swift:9` (заголовок окна и создание сервиса)
- Изменить: `Sources/Pathway/MainWindow.swift` (тулбар с значком, запуск проверки)
- Изменить: `Sources/Pathway/AppCommands.swift` (пункт меню «Проверить обновления…»)

**Интерфейсы:**
- Использует: `UpdateService`, `UpdateState` из задачи 4
- Даёт: `UpdateBadgeView(service:)` — вью для тулбара

- [ ] **Шаг 1: Создаём вью значка**

Создать `Sources/Pathway/UpdateBadgeView.swift`:

```swift
import PathwayCore
import SwiftUI

/// Версия приложения в правом углу строки заголовка. При появлении обновления
/// превращается в кнопку.
///
/// Место выбрано так, чтобы номер версии был всегда на виду — вопрос «какая у
/// меня версия» возникает у коллег чаще, чем открывается «О программе».
struct UpdateBadgeView: View {
    @Bindable var service: UpdateService
    @State private var showNotes = false

    var body: some View {
        switch service.state {
        case .idle, .checking:
            Text(service.currentVersion.description)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("Версия \(service.currentVersion). Нажмите, чтобы проверить обновления.")
                .onTapGesture { Task { await service.checkManually() } }

        case .available(let release):
            Button {
                Task { await service.download() }
            } label: {
                Label("\(release.version)", systemImage: "arrow.down.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
            .help("Доступна версия \(release.version). Нажмите, чтобы обновиться.")
            .onHover { showNotes = $0 }
            .popover(isPresented: $showNotes, arrowEdge: .bottom) {
                notes(release.notes, version: release.version.description)
            }

        case .downloading(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 60)
                Text("\(Int(progress * 100)) %")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

        case .readyToRestart:
            Button("Перезапустить") { service.restart() }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .help("Обновление готово. Приложение закроется и откроется заново.")

        case .failed(let message):
            Label("Ошибка", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(message)
                .onTapGesture { Task { await service.checkManually() } }
        }
    }

    private func notes(_ text: String, version: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Версия \(version)").font(.headline)
            if text.isEmpty {
                Text("Описание изменений не приложено.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(text).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
        }
        .padding()
        .frame(width: 320)
    }
}
```

- [ ] **Шаг 2: Правим заголовок окна и создаём сервис**

В `Sources/Pathway/PathwayApp.swift` заменить содержимое на:

```swift
import PathwayCore
import SwiftUI

@main
struct PathwayApp: App {
    @State private var appState = AppState()
    /// Сервис живёт в App, а не в окне: до него дотягивается пункт главного меню.
    @State private var updates = UpdateService()

    var body: some Scene {
        // Заголовок «Проводник», а не «Pathway»: внутреннее имя продукта
        // пользователю нигде не показывается.
        Window("Проводник", id: "main") {
            MainWindow(updates: updates)
                .environment(appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands(state: appState, updates: updates)
        }
    }
}
```

- [ ] **Шаг 3: Встраиваем значок в тулбар**

В `Sources/Pathway/MainWindow.swift` добавить свойство после `@State private var connectModel`:

```swift
    /// Сервис обновлений приходит из App: тот же экземпляр видит пункт меню.
    let updates: UpdateService
```

Изменить `init()` на:

```swift
    init(updates: UpdateService) {
        self.updates = updates
        // Диалог и сайдбар должны видеть одно состояние подключений.
        let connection = ServerConnection()
        _connection = State(initialValue: connection)
        _connectModel = State(initialValue: ConnectServerModel(connection: connection))
    }
```

Добавить модификатор тулбара сразу после закрывающей скобки `NavigationSplitView` — перед
существующим `.onAppear`:

```swift
        .toolbar {
            ToolbarItem(placement: .automatic) {
                UpdateBadgeView(service: updates)
            }
        }
```

В существующем `.onAppear` добавить последней строкой:

```swift
            // Бандл предыдущей версии больше не нужен: раз мы выполняемся,
            // обновление удалось.
            BundleUpdateInstaller.cleanUpAfterUpdate()
            Task { await updates.checkAutomatically() }
```

- [ ] **Шаг 4: Добавляем пункт меню**

В `Sources/Pathway/AppCommands.swift` добавить свойство в структуру рядом с существующим `state`:

```swift
    let updates: UpdateService
```

И добавить группу команд рядом с остальными `CommandGroup`:

```swift
        // Рядом с «О программе» — там этот пункт ищут по традиции macOS.
        CommandGroup(after: .appInfo) {
            Button("Проверить обновления…") {
                Task { await updates.checkManually() }
            }
        }
```

- [ ] **Шаг 5: Проверяем сборку**

Выполнить: `swift build`
Ожидается: сборка без ошибок.

- [ ] **Шаг 6: Собираем приложение и смотрим глазами**

Выполнить: `./build-app.sh`

Внимание: скрипт закроет запущенное приложение и перезапишет `/Applications/Проводник.app`.

Открыть приложение и проверить:
- в правом углу строки заголовка тусклым виден номер версии
- заголовок окна — «Проводник», а не «Pathway»
- в меню «Проводник» есть «Проверить обновления…»
- клик по номеру версии запускает проверку (релизов ещё нет — состояние не меняется)

- [ ] **Шаг 7: Коммит**

```bash
git add Sources/Pathway/UpdateBadgeView.swift Sources/Pathway/PathwayApp.swift \
        Sources/Pathway/MainWindow.swift Sources/Pathway/AppCommands.swift
git commit -m "UI обновлений: значок версии в строке заголовка

Номер версии всегда на виду в правом углу заголовка: вопрос «какая у меня
версия» возникает у коллег чаще, чем открывается «О программе». При появлении
релиза номер превращается в кнопку, дальше — прогресс и «Перезапустить».

Сервис создаётся в App, а не в окне: до него должен дотягиваться пункт
главного меню, а .commands строится в App и не видит @State окна — по той же
причине там же живёт AppState.

Заодно исправлен заголовок окна: там стояло внутреннее имя продукта «Pathway»,
хотя пользователю везде видно «Проводник»."
```

---

### Задача 6: Скрипт выпуска релиза

**Файлы:**
- Создать: `release.sh`
- Изменить: `Resources/Info.plist` (версия `0.1` → `1.0.0`)

**Интерфейсы:**
- Использует: `gh` CLI (установлен, аккаунт koklish)
- Даёт: `./release.sh <версия>` — выпуск релиза одной командой

- [ ] **Шаг 1: Поднимаем версию до 1.0.0**

В `Resources/Info.plist` заменить:

```xml
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
```

на:

```xml
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
```

- [ ] **Шаг 2: Пишем скрипт**

Создать `release.sh`:

```bash
#!/bin/bash
# Выпускает релиз: поднимает версию, собирает бандл, публикует на GitHub.
#
# Использование: ./release.sh 1.1.0
set -euo pipefail

VERSION="${1:-}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Проводник"
PLIST="$ROOT/Resources/Info.plist"

if [ -z "$VERSION" ]; then
    echo "Использование: ./release.sh <версия>, например ./release.sh 1.1.0" >&2
    exit 1
fi

# Версия должна выглядеть как 1.2.3: по ней приложение решает, обновляться ли,
# и разбор нестандартной строки просто вернёт nil — обновления тихо перестанут приходить.
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Версия должна быть вида 1.2.3, получено: $VERSION" >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "Рабочее дерево не чистое. Закоммитьте или отложите изменения." >&2
    exit 1
fi

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "Тег v$VERSION уже существует." >&2
    exit 1
fi

if ! command -v gh >/dev/null; then
    echo "Нужен GitHub CLI: brew install gh" >&2
    exit 1
fi

# Версия проставляется в Info.plist и в тег из одного значения: разойдись они,
# коллеги получали бы предложение обновиться, уже стоя на новой версии.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
# CFBundleVersion должен расти монотонно — берём число коммитов.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$PLIST"

echo "Собираю $APP_NAME $VERSION…"

# Собираем во временной директории, а не через build-app.sh: тот закрывает
# запущенное приложение и перезаписывает /Applications. Выпуск релиза не должен
# трогать рабочую копию разработчика.
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
APP="$BUILD_DIR/$APP_NAME.app"

swift build -c release --product Pathway

if [ ! -f "$ROOT/Resources/AppIcon.icns" ] || [ "$ROOT/Resources/AppIcon.svg" -nt "$ROOT/Resources/AppIcon.icns" ]; then
    "$ROOT/Tools/make-icon.sh"
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Pathway" "$APP/Contents/MacOS/Pathway"
cp "$PLIST" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Тот же идентификатор подписи, что в build-app.sh: macOS помнит выданные
# разрешения по идентичности подписи, и обновлённая копия должна остаться для
# системы тем же приложением — иначе доступ к папкам и Связке ключей спросят заново.
codesign --force --sign - --identifier com.pathway.filemanager \
    --entitlements "$ROOT/Resources/Pathway.entitlements" "$APP"

ARCHIVE="$BUILD_DIR/$APP_NAME-$VERSION.zip"
# ditto, а не zip: сохраняет расширенные атрибуты и симлинки внутри бандла,
# без которых подпись развалится.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

# Заметки к выпуску — из коммитов после прошлого тега.
PREVIOUS_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [ -n "$PREVIOUS_TAG" ]; then
    NOTES="$(git log --pretty='- %s' "$PREVIOUS_TAG"..HEAD)"
else
    NOTES="Первый выпуск."
fi

git add "$PLIST"
git commit -m "Версия $VERSION"
git tag "v$VERSION"

echo "Публикую релиз…"
git push origin main
git push origin "v$VERSION"
gh release create "v$VERSION" "$ARCHIVE" \
    --title "$APP_NAME $VERSION" \
    --notes "$NOTES"

echo "Готово: версия $VERSION опубликована."
echo "Коллеги увидят предложение обновиться в течение суток."
```

- [ ] **Шаг 3: Делаем скрипт исполняемым**

Выполнить: `chmod +x release.sh`

- [ ] **Шаг 4: Проверяем, что скрипт отвергает мусор**

Выполнить: `./release.sh` — ожидается подсказка об использовании и код возврата 1.
Выполнить: `./release.sh abc` — ожидается «Версия должна быть вида 1.2.3».

Проверять выпуск настоящего релиза здесь **не нужно**: публикация видна коллегам и запускает у
них обновление. Это делает пользователь сам.

- [ ] **Шаг 5: Коммит**

```bash
git add release.sh Resources/Info.plist
git commit -m "Выпуск релиза одной командой

./release.sh 1.1.0 поднимает версию в Info.plist, собирает подписанный бандл,
пакует его и публикует на GitHub. Версия в Info.plist и тег берутся из одного
значения: разойдись они, коллеги получали бы предложение обновиться, уже стоя
на новой версии.

Сборка идёт во временной директории, а не через build-app.sh: тот закрывает
запущенное приложение и перезаписывает /Applications, а выпуск релиза не
должен трогать рабочую копию.

Начальная версия поднята с 0.1 до 1.0.0: приложением уже пользуются, и
черновиком оно не выглядит."
```

---

### Задача 7: Ручная проверка обновления целиком

Автотестами это не покрыть: проверка требует настоящего релиза на GitHub и подмены установленной
копии приложения.

**Эту задачу выполняет пользователь**, а не агент: она включает публикацию релиза.

- [ ] **Шаг 1: Выпустить первый релиз**

```bash
./release.sh 1.0.0
```

- [ ] **Шаг 2: Убедиться, что значок показывает 1.0.0 и обновлений нет**

- [ ] **Шаг 3: Внести любое видимое изменение и выпустить 1.0.1**

```bash
./release.sh 1.0.1
```

- [ ] **Шаг 4: Проверить полный цикл в установленной копии**

Открыть `/Applications/Проводник.app` (версии 1.0.0) и пройти чек-лист спеки:
- значок стал акцентным, показывает `↓ 1.0.1`
- наведение показывает заметки к выпуску
- клик запускает скачивание, прогресс двигается
- появляется «Перезапустить», нажатие закрывает и открывает приложение
- в заголовке новая версия, значок снова тусклый
- закладки, избранное и пароли серверов на месте
- `/Applications/Проводник.app.old` исчез после успешного запуска

- [ ] **Шаг 5: Проверить поведение без сети**

Выключить Wi-Fi, запустить приложение — ошибок быть не должно. Кликнуть по значку версии —
должен появиться значок ошибки с текстом при наведении.

---

## Самопроверка плана

**Покрытие спеки:**
- Причина работоспособности без Developer ID → зафиксирована в общих ограничениях (запрет на
  `LSFileQuarantineEnabled`)
- `AppVersion`, `ReleaseInfo`, `UpdateState`, `UpdateService` → задачи 1, 2, 4
- Протоколы `ReleaseFetching`, `UpdateInstalling` → задачи 2, 3
- `UpdateBadgeView` с четырьмя состояниями → задача 5
- Пункт меню «Проверить обновления…» → задача 5, шаг 4
- Проверка раз в сутки, молчание при автопроверке → задача 4, тесты
- Распаковка `ditto`, проверки до подмены, скрипт-помощник, откат → задача 3
- Уборка `.old` при старте → задача 3 (`cleanUpAfterUpdate`) + задача 5 (вызов)
- `release.sh` → задача 6
- Версия `1.0.0`, заголовок «Проводник» → задачи 6 и 5
- Все пункты ручного чек-листа → задача 7

**Согласованность имён:** `AppVersion.init?(_:)`, `ReleaseFetching.latestRelease()`,
`UpdateInstalling.install(archive:)`, `BundleUpdateInstaller.cleanUpAfterUpdate()`,
`UpdateService.checkAutomatically()/checkManually()/download()/restart()` — совпадают между
задачами, где определены и где используются.

**Заглушек нет:** каждый шаг содержит код целиком.
