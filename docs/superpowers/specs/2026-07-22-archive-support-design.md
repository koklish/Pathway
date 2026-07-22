# Спека: архивация и распаковка

Дата: 2026-07-22

## Цель

Работа с архивами в Pathway без внешних зависимостей — только системные инструменты macOS (`/usr/bin/zip`, `/usr/bin/bsdtar`), запускаемые через `Process`.

Возможности:
- Двойной клик по архиву — автоматическая распаковка рядом с архивом («умно», как Finder).
- Контекстное меню для файлов/папок (в т.ч. множественное выделение) — «Архивировать…» с диалогом выбора формата и пароля.
- Контекстное меню для архива — «Распаковать здесь» и «Распаковать в…» (выбор папки).

## Форматы

| Операция | Форматы |
|---|---|
| Создание | zip (с паролем ZipCrypto), tar.gz, tar.bz2, tar.xz |
| Распаковка | zip (включая зашифрованные, через `bsdtar --passphrase`), tar, tar.gz, tar.bz2, tar.xz, 7z, RAR/RAR5 |

Ограничения (сообщаются пользователю понятной ошибкой):
- Пароль при создании — только для zip (шифрование ZipCrypto).
- Зашифрованные 7z и RAR распаковать нельзя (не поддерживается системным bsdtar).

## Архитектура

### 1. `ArchiveService` (Sources/PathwayCore/ArchiveService.swift)

Сервис по образцу `FileOperations`, вся работа через `Process`.

- `ArchiveFormat` — enum форматов создания: `.zip`, `.tarGz`, `.tarBz2`, `.tarXz`; у каждого расширение и человекочитаемое имя. `supportsPassword == true` только у `.zip`.
- `static func isArchive(_ url: URL) -> Bool` — по расширениям: `zip, tar, tar.gz, tgz, tar.bz2, tbz, tbz2, tar.xz, txz, 7z, rar`.
- `create(items: [URL], format: ArchiveFormat, password: String?, archiveName: String, in directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL`
  - zip: `/usr/bin/zip -r -y [-P пароль] архив.zip элементы…` с рабочей директорией `directory` (относительные пути).
  - tar.*: `/usr/bin/bsdtar -c -a -f архив.tar.xx элементы…` (флаг сжатия по расширению), рабочая директория `directory`.
  - Конфликт имени архива — суффикс «Имя 2» (паттерн `ConflictResolution` из `FileOperations`).
- `extract(archive: URL, to directory: URL, password: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL`
  - Листинг `bsdtar -tf` — общее число записей (для прогресса) и элементы верхнего уровня.
  - «Умное» поведение Finder: один элемент верхнего уровня → извлекается прямо в `directory`; несколько → создаётся папка с именем архива (без расширения). Конфликты имён → «Имя 2».
  - Извлечение в скрытую временную папку `.pathway-extract-<uuid>` внутри `directory`, затем перемещение результата на место. При ошибке/отмене временная папка удаляется — мусора не остаётся.
  - Команда: `bsdtar -x -v [--passphrase пароль] -f архив -C временная-папка`.
- Прогресс: подсчёт строк построчного вывода `-v` (у zip — его стандартный вывод по файлам), делённый на общее число записей. Колбэк вызывается не чаще ~10 раз/сек.
- Отмена: методы уважают `Task.isCancelled`; при отмене процесс завершается (`terminate`), временные файлы удаляются, бросается `CancellationError`.
- Ошибки — `ArchiveError`:
  - `.passwordRequired` / `.wrongPassword` — распознаются по stderr (`Passphrase required`, `Incorrect passphrase` и аналоги);
  - `.encryptedUnsupported` — зашифрованный 7z/RAR;
  - `.toolFailed(String)` — прочие сбои с текстом stderr.

### 2. `BrowserModel` (интеграция)

- `open(_:)`: если `ArchiveService.isArchive(item.url)` — вместо `NSWorkspace.open` запускается `extract(item:)` в папку архива.
- Новые методы:
  - `compress(items: [FileItem], format: ArchiveFormat, password: String?, name: String)`
  - `extract(_ item: FileItem, to directory: URL? = nil)` — `nil` означает «рядом с архивом».
- Оба — фоновая `Task` по образцу `reloadAsync`: `Task.detached`, обновление `operationProgress` на MainActor, по завершении инвалидация кэша и `reload()`, ошибки в `errorMessage`. Хранится ссылка `operationTask` для отмены; заголовок операции — `operationTitle: String?`.
- Пароль при распаковке: первая попытка без пароля; при `ArchiveError.passwordRequired`/`.wrongPassword` модель выставляет `passwordRequest` (URL архива + целевая папка + флаг «пароль был неверный») — UI показывает диалог, после ввода повтор с паролем.

### 3. UI

- **Контекстное меню** (`FileListView.menuNeedsUpdate`):
  - выделены обычные элементы → пункт «Архивировать…» (работает и для нескольких);
  - выделен один архив → «Распаковать здесь», «Распаковать в…» (`NSOpenPanel`, выбор только папки).
- **Диалог архивации** — SwiftUI sheet по образцу `ConnectServerView`/`showConnectServer` в `MainWindow`:
  - имя архива (по умолчанию: имя единственного элемента или «Архив»);
  - Picker формата (zip по умолчанию);
  - поля «Пароль» и «Подтверждение» — видимы/активны только для zip; при несовпадении кнопка «Создать» неактивна;
  - кнопки «Отмена» / «Создать».
- **Диалог пароля** при распаковке зашифрованного архива: поле пароля, при повторе после неверного пароля — красная подпись «Неверный пароль».
- **Статус-бар** (`StatusBarView`): существующий `ProgressView(value: operationProgress)` дополняется подписью операции («Архивация…» / «Распаковка…») и кнопкой отмены (✕), вызывающей `model.cancelOperation()`.

## Поток данных

1. Пользователь инициирует операцию (двойной клик / меню / диалог).
2. `BrowserModel` создаёт фоновую `Task`, выставляет `operationTitle` и `operationProgress = 0`.
3. `ArchiveService` запускает процесс, стримит прогресс через колбэк → модель обновляет `operationProgress`.
4. Завершение: сброс прогресса, инвалидация `DirectoryCache`, `reload()`. Ошибка → `errorMessage` (alert в `MainWindow`). Нужен пароль → `passwordRequest` → диалог → повтор.

## Тесты (PathwayCoreTests/ArchiveServiceTests.swift)

На временных каталогах (`FileManager.temporaryDirectory`):
- создание и распаковка каждого формата (zip, tar.gz, tar.bz2, tar.xz) — содержимое совпадает;
- «умная» распаковка: архив с одной папкой верхнего уровня → без обёртки; с несколькими элементами → папка с именем архива;
- конфликт имён при создании и распаковке → суффикс « 2»;
- zip с паролем: распаковка с верным паролем успешна; без пароля → `.passwordRequired`; с неверным → `.wrongPassword`;
- `isArchive` — позитивные и негативные случаи (включая `tar.gz` как двойное расширение);
- отмена: запуск распаковки большого архива, отмена Task → временных папок не осталось.

## Вне рамок

- Создание 7z и RAR, AES-шифрование (потребуют внешних бинарей).
- Просмотр содержимого архива без распаковки.
- Очередь из нескольких одновременных операций (одна операция за раз; пункты меню неактивны, пока идёт операция).
