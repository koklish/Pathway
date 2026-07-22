# Спека: главное меню, команды и горячие клавиши

Дата: 2026-07-22

## Цель

Единый слой команд как источник правды для главного меню, контекстного меню и горячих клавиш.

Сейчас действия описаны в трёх независимых местах: `@objc menu*` в `FileListView`, кнопки в `SidebarView`, `.keyboardShortcut` в `AddressBarView`. Главного меню приложения нет вообще (`PathwayApp.commands` только удаляет пункт «New»), у пунктов контекстного меню `keyEquivalent` пуст, шорткатов реализовано пять из заявленных в основной спеке.

Итог работы:
- Главное меню «Файл / Правка / Вид / Переход» с рабочими шорткатами.
- Одно определение команды даёт заголовок, иконку, шорткат, доступность и исполнение.
- Клавиши работают из списка файлов, а не только при фокусе на конкретной кнопке.

## Архитектура

### 1. Владение моделью

`BrowserModel` переезжает из приватного `@State` в `MainWindow` внутрь `AppState`:

```swift
public final class AppState {
    public let browser: BrowserModel
    public let favorites: FavoritesStore
    public let folderActions: FolderActions
    public var showHiddenFiles = false
    public var isEditingText = false
}
```

`AppState.init` создаёт `BrowserModel(path: FileManager.default.homeDirectoryForCurrentUser)`; путь остаётся параметром инициализатора со значением по умолчанию, чтобы тесты могли подставить свой.

`MainWindow` использует `appState.browser` вместо собственного `@State`; передача вниз по параметрам (`SidebarView(model:)`, `AddressBarView(model:)`, `FileListView(model:)`, `StatusBarView(model:)`) не меняется.

`.commands` в `PathwayApp` захватывает `appState` — тот же объект, что и `MainWindow`, поскольку `BrowserModel` и `AppState` — ссылочные `@Observable`-классы.

Отвергнуто: `focusedSceneValue` — канонический путь SwiftUI для меню, зависящих от окна, но окно одно (`Window`, не `WindowGroup`), выигрыш не окупает кода. Поднятие второго `@State` в `App` — параллельный канал передачи рядом с уже существующим `AppState`.

`browser` в `AppState` — крючок под будущий two-pane: при переходе на две панели он станет `activePane`.

### 2. Слой команд (Sources/PathwayCore/Commands.swift)

Плоская таблица; команда — значение, контекст берёт из `AppState`.

```swift
public enum CommandID: String, CaseIterable, Sendable {
    case newFolder, open, rename, compress, extractHere, revealInFinder, openTerminal, openClaude
    case copy, cut, paste, selectAll, moveToTrash
    case toggleHiddenFiles, refresh
    case goBack, goForward, goUp, editPath, toggleFavorite
}

public struct Shortcut: Sendable, Equatable {
    public let key: Key                 // .character(Character) | .upArrow | .downArrow | .delete | .f2
    public let modifiers: Modifiers     // OptionSet: .command, .shift, .option, .control
}

public struct AppCommand: Identifiable, Sendable {
    public let id: CommandID
    public let title: String
    public let shortcut: Shortcut?
    public let icon: String?                        // SF Symbol
    public let isEnabled: @MainActor (AppState) -> Bool
    public let run: @MainActor (AppState) -> Void
}

public enum CommandRegistry {
    public static let all: [AppCommand]
    public static subscript(id: CommandID) -> AppCommand
}
```

`Shortcut.Key` и `Shortcut.Modifiers` — собственные типы, чтобы `PathwayCore` не зависел от SwiftUI. Преобразование в `KeyEquivalent`/`EventModifiers` (SwiftUI) и в `keyEquivalent`/`keyEquivalentModifierMask` (AppKit) живёт в `Sources/Pathway/ShortcutBridge.swift`.

`run` и `isEnabled` обращаются к `AppState`: выделение — `appState.browser.pane.selection`, операции — `appState.browser`, избранное и внешние приложения — `appState.folderActions`.

Команды, требующие UI-реакции (диалог архивации, старт инлайн-переименования, фокус адресной строки), не могут исполниться внутри `PathwayCore` — они выставляют запрос в наблюдаемое свойство, а UI на него реагирует:

```swift
public final class AppState {
    public var pendingRename: URL?      // MainWindow пробрасывает в renamingItem
    public var pendingCompress: [FileItem]?
    public var pendingEditPath = false  // AddressBarView начинает редактирование
}
```

`MainWindow` уже держит `renamingItem` и `compressItems` как `@State`; они заменяются на эти поля `AppState`, чтобы у команд и у контекстного меню была общая точка.

### 3. Доступность и модальные состояния

Гашение команд при вводе текста — гибрид responder chain и явного флага.

Responder chain работает сам: когда первый респондер — `NSTextField`/`NSTextView`, он перехватывает `⌘C`, `⌘X`, `⌘V`, `⌘A` как текстовые операции, и до пунктов меню они не доходят. Это заодно чинит текущий баг: в адресной строке `⌘C` сейчас не копирует текст.

Флаг `AppState.isEditingText` нужен для клавиш, которые текстовое поле не перехватывает: `F2`, `⌘⌫`, `⌘⇧N`, `⌘↓`. Все команды из групп «Файл» и «Правка» включают `!appState.isEditingText` в `isEnabled`.

Флаг поднимается и опускается в трёх местах:
- инлайн-переименование — `FileListView.Coordinator`, в момент `makeFirstResponder(field)` и в `controlTextDidEndEditing` / `control(_:textView:doCommandBy:)` при отмене;
- адресная строка — `AddressBarView`, в `onChange(of: fieldFocused)` (уже существует);
- модальные sheet'ы — `MainWindow`, в `.onAppear`/`.onDisappear` каждого sheet (архивация, пароль, подключение сервера).

Чтобы флаг не залипал при закрытии диалога нештатным путём, опускание привязано к `.onDisappear` sheet'а, а не к кнопкам «Отмена»/«ОК».

### 4. Главное меню (Sources/Pathway/AppCommands.swift)

Структура `AppCommands: Commands`, получает `AppState` параметром из `PathwayApp`. Пункт строится из команды единообразно:

```swift
private func item(_ id: CommandID) -> some View {
    let cmd = CommandRegistry[id]
    return Button(cmd.title) { cmd.run(state) }
        .disabled(!cmd.isEnabled(state))
        .modifier(ShortcutModifier(cmd.shortcut))
}
```

Состав:

| Меню | Пункты |
|---|---|
| Файл | Новая папка `⌘⇧N` · Открыть `⌘↓` · Переименовать `F2` · Архивировать… · Распаковать здесь · Показать в Finder `⌘⇧R` · Открыть в Терминале `⌘⇧T` · Открыть в Claude Code |
| Правка | Копировать `⌘C` · Вырезать `⌘X` · Вставить `⌘V` · Выбрать всё `⌘A` · Переместить в Корзину `⌘⌫` |
| Вид | Показывать скрытые файлы `⌘⇧.` · Обновить `⌘R` |
| Переход | Назад `⌘[` · Вперёд `⌘]` · Вверх `⌘↑` · Перейти к папке… `⌘L` · Добавить в избранное `⌘D` |

Размещение: «Файл» и «Правка» — `CommandGroup(replacing:)` для `.newItem` и `.pasteboard`; «Вид» — `CommandGroup(after: .sidebar)`; «Переход» — отдельное `CommandMenu("Переход")`.

Отступления от исходной спеки основного проекта, принятые сознательно:
- **Корзина — `⌘⌫`, не голый `⌫`.** Голый Backspace в Finder не удаляет; в списке с type-select он опасен.
- **Открыть — `⌘↓`**, как в Finder. `Enter` в macOS-списках означает «переименовать» и уже занят завершением инлайн-переименования.
- **`F2` сохраняется** как переименование — привычка пользователей Windows, конфликта с системой нет.
- **`⌘R` (Обновить) переезжает** из `AddressBarView` в меню.

### 5. Снятие шорткатов с кнопок

`.keyboardShortcut` удаляется с кнопок в `AddressBarView` (строки 27, 32, 36, 40) и убирается невидимая кнопка-хак для `⌘L` (строки 61–66). Сами кнопки и их `.disabled(...)` остаются.

Это чинит существующий баг: шорткат, привязанный к `.disabled`-кнопке, не срабатывает, поэтому `⌘[` сейчас мёртв ровно тогда, когда история пуста, — но остаётся мёртвым и после появления истории, пока фокус не вернётся в нужное место.

### 6. Контекстное меню

Контекстное меню списка продолжает работать от `table.clickedRow`, а не от выделения: правый клик по невыделенному файлу действует на этот файл. Это нативное поведение macOS, и оно сохраняется.

Меняется только источник оформления — `FileListView.add(...)` получает `CommandID` и берёт из реестра заголовок, иконку и `keyEquivalent`:

```swift
private func add(to menu: NSMenu, _ id: CommandID, _ action: Selector?) {
    let cmd = CommandRegistry[id]
    let item = NSMenuItem(title: cmd.title, action: action, keyEquivalent: cmd.shortcut?.appKitKey ?? "")
    item.keyEquivalentModifierMask = cmd.shortcut?.appKitModifiers ?? []
    item.target = self
    item.image = cmd.icon.map(MenuIcon.image(named:))
    menu.addItem(item)
}
```

`@objc menu*`-методы остаются как есть — они работают от `clickedItem` и это правильно. Реестр здесь источник правды для *определения* команды (как называется, как выглядит, какой у неё шорткат), но не для контекста исполнения.

Так отображаемые в контекстном меню шорткаты гарантированно совпадают с реально работающими, и переименование пункта делается в одном месте.

### 7. Клавиши в списке файлов

`NSTableView` бесплатно даёт стрелки, `⌘`/`⇧`-выделение и type-select — это сохраняется.

Все команды из таблицы работают через главное меню: AppKit сам доставляет `keyEquivalent` до пункта меню, когда фокус в таблице. Дополнительный `NSEvent`-монитор или `keyDown`-перехват не нужен.

Исключение — `F2`: функциональные клавиши как `keyEquivalent` в меню работают, но требуют `NSMenuItem.keyEquivalent = "\u{F708}"` (`NSF2FunctionKey`) с пустой маской модификаторов. Это учитывается в `ShortcutBridge`.

## Поток данных

1. Пользователь нажимает клавишу или выбирает пункт меню.
2. AppKit/SwiftUI доставляет событие пункту меню; `.disabled` отсекает недоступные команды (включая случай `isEditingText`).
3. `cmd.run(appState)` вызывает метод `BrowserModel`/`FolderActions` либо выставляет `pending*`-запрос.
4. Для `pending*`: `MainWindow`/`AddressBarView` наблюдают свойство, показывают диалог или начинают редактирование, затем сбрасывают его в `nil`/`false`.

## Тесты (PathwayCoreTests/CommandsTests.swift)

`CommandRegistry` тестируется без UI, на `AppState` с временным каталогом:

- каждый `CommandID` присутствует в `all` ровно один раз (`CaseIterable` против реестра);
- шорткаты уникальны — нет двух команд с одинаковой парой «клавиша + модификаторы»;
- `isEnabled` при пустом выделении: `copy`, `cut`, `moveToTrash`, `rename`, `compress` недоступны; `newFolder`, `paste`, `refresh`, `toggleHiddenFiles` доступны;
- `isEnabled` при `isEditingText == true`: все команды групп «Файл» и «Правка» недоступны;
- `goBack`/`goForward` следуют `pane.canGoBack`/`canGoForward`; `goUp` недоступен в корне;
- `run` для `copy`/`cut`/`paste` меняет состояние `BrowserModel` так же, как прямой вызов методов модели;
- `run` для `rename`/`compress`/`editPath` выставляет соответствующее `pending*`-свойство, а не выполняет операцию.

Проверка доставки клавиш до меню — ручная, по чек-листу (UI-тесты в проекте не используются).

## Ручной чек-лист

- `⌘C`/`⌘V` в списке копируют файлы; в адресной строке и в поле переименования — текст.
- `F2` и `⌘⌫` в поле переименования не срабатывают как файловые команды.
- `⌘⌫` отправляет выделение в корзину; при пустом выделении пункт неактивен.
- `⌘[`/`⌘]` работают после навигации, независимо от фокуса.
- Шорткаты, показанные в контекстном меню, совпадают с работающими.
- Закрытие диалога архивации клавишей Esc не оставляет `isEditingText` поднятым (проверяется последующим `F2`).

## Вне рамок

- Пользовательская настройка шорткатов (переназначение клавиш).
- Панель «Помощь» с поиском по меню (даётся системой бесплатно).
- Two-pane и понятие активной панели — `AppState.browser` подготовлен как крючок, но сам переход не делается.
- Меню «Окно» и «Приложение» — остаются системными по умолчанию.
