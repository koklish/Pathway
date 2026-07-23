import Foundation

/// Клавиша шортката. Собственный тип, а не KeyEquivalent из SwiftUI: PathwayCore
/// не зависит от UI-фреймворков, преобразование живёт в Sources/Pathway.
public enum ShortcutKey: Sendable, Equatable {
    case character(Character)
    case upArrow
    case downArrow
    case delete
    case f2
    case tab
}

public struct ShortcutModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let shift = ShortcutModifiers(rawValue: 1 << 1)
    public static let option = ShortcutModifiers(rawValue: 1 << 2)
    public static let control = ShortcutModifiers(rawValue: 1 << 3)
}

public struct Shortcut: Sendable, Equatable {
    public let key: ShortcutKey
    public let modifiers: ShortcutModifiers

    public init(_ key: ShortcutKey, _ modifiers: ShortcutModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public static func == (lhs: Shortcut, rhs: Shortcut) -> Bool {
        lhs.key == rhs.key && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }
}

public enum CommandID: String, CaseIterable, Sendable {
    // Файл
    case newFolder, open, rename, compress, extractHere, revealInFinder, openTerminal, openClaude
    // Правка
    case copy, cut, paste, selectAll, moveToTrash
    // Вид
    case toggleHiddenFiles, refresh
    // Переход
    case goBack, goForward, goUp, editPath, toggleFavorite
    // Вкладки
    case newTab, closeTab, nextTab, previousTab, openInNewTab
}

/// Команда приложения: единственное описание действия, из которого строятся
/// главное меню, контекстное меню и горячая клавиша.
public struct AppCommand: Identifiable, Sendable {
    public let id: CommandID
    public let title: String
    public let shortcut: Shortcut?
    /// Имя символа SF Symbols; nil — пункт без иконки.
    public let icon: String?
    public let isEnabled: @MainActor @Sendable (AppState) -> Bool
    public let run: @MainActor @Sendable (AppState) -> Void
}

/// Реестр всех команд. Источник правды: заголовок, иконка, шорткат и доступность
/// описаны здесь один раз, а меню и клавиши только отражают их.
public enum CommandRegistry {
    /// Команды, меняющие содержимое диска: на томе только для чтения они
    /// недоступны.
    ///
    /// «Вырезать» в списке потому, что пишет тоже — исходник удаляется при
    /// вставке. «Архивировать» — потому что архив создаётся рядом с
    /// исходником, а не во временной папке.
    public static let writesToDisk: Set<CommandID> = [
        .newFolder, .rename, .moveToTrash, .paste, .cut, .compress,
    ]

    public static subscript(id: CommandID) -> AppCommand {
        // Реестр строится из CommandID.allCases, поэтому промах невозможен —
        // он означал бы, что команда забыта в table, и это ошибка программиста.
        guard let command = table[id] else {
            preconditionFailure("Команда \(id.rawValue) не описана в CommandRegistry")
        }
        return command
    }

    public static let all: [AppCommand] = [
        // MARK: Файл

        AppCommand(
            id: .newFolder,
            title: "Новая папка",
            shortcut: Shortcut(.character("n"), [.command, .shift]),
            icon: "folder.badge.plus",
            isEnabled: { !$0.isEditingText && !$0.browser.isReadOnlyVolume },
            run: { $0.browser.createFolder() }
        ),
        AppCommand(
            id: .open,
            title: "Открыть",
            shortcut: Shortcut(.downArrow, .command),
            icon: "arrow.up.forward.app",
            isEnabled: { !$0.isEditingText && !$0.browser.selectedItems.isEmpty },
            run: { state in state.browser.selectedItems.forEach { state.browser.open($0) } }
        ),
        AppCommand(
            id: .rename,
            title: "Переименовать",
            shortcut: Shortcut(.f2),
            icon: "pencil",
            // Переименование за раз только одного элемента: инлайн-редактор в списке один.
            isEnabled: { !$0.isEditingText && !$0.browser.isReadOnlyVolume && $0.browser.pane.selection.count == 1 },
            run: { $0.pendingRename = $0.browser.pane.selection.first }
        ),
        AppCommand(
            id: .compress,
            title: "Архивировать…",
            shortcut: nil,
            icon: "archivebox",
            isEnabled: { !$0.isEditingText && !$0.browser.isReadOnlyVolume && !$0.browser.selectedItems.isEmpty && !$0.browser.isBusy },
            run: { $0.pendingCompress = $0.browser.selectedItems }
        ),
        AppCommand(
            id: .extractHere,
            title: "Распаковать здесь",
            shortcut: nil,
            icon: "archivebox",
            isEnabled: { state in
                guard !state.isEditingText, !state.browser.isBusy else { return false }
                let items = state.browser.selectedItems
                return items.count == 1 && ArchiveService.isArchive(items[0].url)
            },
            run: { state in state.browser.selectedItems.first.map { state.browser.extract($0) } }
        ),
        AppCommand(
            id: .revealInFinder,
            title: "Показать в Finder",
            shortcut: Shortcut(.character("r"), [.command, .shift]),
            icon: "macwindow",
            isEnabled: { _ in true },
            run: { $0.folderActions.revealInFinder($0.browser.commandTarget) }
        ),
        AppCommand(
            id: .openTerminal,
            title: "Открыть в Терминале",
            shortcut: Shortcut(.character("t"), [.command, .shift]),
            icon: "terminal",
            isEnabled: { _ in true },
            run: { $0.folderActions.openTerminal(at: $0.browser.commandFolder) }
        ),
        AppCommand(
            id: .openClaude,
            title: "Открыть в Claude Code",
            shortcut: nil,
            icon: nil,
            isEnabled: { $0.folderActions.isClaudeAvailable },
            run: { $0.folderActions.openClaude(at: $0.browser.commandFolder) }
        ),

        // MARK: Правка

        // Буферные команды намеренно без шортката: ⌘C/⌘X/⌘V/⌘A принадлежат
        // стандартным пунктам меню «Правка» с селекторами copy:/paste:/
        // selectAll: и target = nil. AppKit доставляет их по responder chain,
        // поэтому одна клавиша работает и в тексте, и в списке файлов — как в
        // Finder. Свой пункт с тем же шорткатом перехватывал бы клавишу и до
        // NSTextField её не пускал.
        //
        // В реестре они остаются ради контекстного меню списка: заголовок,
        // иконка и доступность нужны и ему.

        AppCommand(
            id: .copy,
            title: "Копировать",
            shortcut: nil,
            icon: "document.on.document",
            isEnabled: { !$0.browser.pane.selection.isEmpty },
            run: { $0.browser.copy() }
        ),
        AppCommand(
            id: .cut,
            title: "Вырезать",
            shortcut: nil,
            icon: "scissors",
            isEnabled: { !$0.browser.isReadOnlyVolume && !$0.browser.pane.selection.isEmpty },
            run: { $0.browser.cut() }
        ),
        AppCommand(
            id: .paste,
            title: "Вставить",
            shortcut: nil,
            icon: "clipboard",
            isEnabled: { !$0.browser.isReadOnlyVolume && $0.browser.canPaste },
            run: { $0.browser.paste() }
        ),
        AppCommand(
            id: .selectAll,
            title: "Выбрать всё",
            shortcut: nil,
            icon: nil,
            isEnabled: { !$0.browser.items.isEmpty },
            run: { $0.browser.selectAll() }
        ),
        AppCommand(
            id: .moveToTrash,
            title: "Переместить в Корзину",
            shortcut: Shortcut(.delete, .command),
            icon: "trash",
            isEnabled: { !$0.isEditingText && !$0.browser.isReadOnlyVolume && !$0.browser.pane.selection.isEmpty },
            run: { $0.browser.moveSelectionToTrash() }
        ),

        // MARK: Вид

        AppCommand(
            id: .toggleHiddenFiles,
            title: "Показывать скрытые файлы",
            shortcut: Shortcut(.character("."), [.command, .shift]),
            icon: "eye",
            isEnabled: { _ in true },
            run: { $0.showHiddenFiles.toggle() }
        ),
        AppCommand(
            id: .refresh,
            title: "Обновить",
            shortcut: Shortcut(.character("r"), .command),
            icon: "arrow.clockwise",
            isEnabled: { _ in true },
            run: { $0.browser.reloadAsync() }
        ),

        // MARK: Переход

        AppCommand(
            id: .goBack,
            title: "Назад",
            shortcut: Shortcut(.character("["), .command),
            icon: "chevron.left",
            isEnabled: { $0.browser.pane.canGoBack },
            run: { $0.browser.goBack() }
        ),
        AppCommand(
            id: .goForward,
            title: "Вперёд",
            shortcut: Shortcut(.character("]"), .command),
            icon: "chevron.right",
            isEnabled: { $0.browser.pane.canGoForward },
            run: { $0.browser.goForward() }
        ),
        AppCommand(
            id: .goUp,
            title: "Вверх",
            shortcut: Shortcut(.upArrow, .command),
            icon: "chevron.up",
            isEnabled: { $0.browser.pane.path.path != "/" },
            run: { $0.browser.goUp() }
        ),
        AppCommand(
            id: .editPath,
            title: "Перейти к папке…",
            shortcut: Shortcut(.character("l"), .command),
            icon: nil,
            isEnabled: { _ in true },
            run: { $0.pendingEditPath = true }
        ),
        AppCommand(
            id: .toggleFavorite,
            title: "Добавить в избранное",
            shortcut: Shortcut(.character("d"), .command),
            icon: "star",
            isEnabled: { _ in true },
            run: { $0.folderActions.toggleFavorite($0.browser.commandFolder) }
        ),

        // MARK: Вкладки

        AppCommand(
            id: .newTab,
            title: "Новая вкладка",
            shortcut: Shortcut(.character("t"), .command),
            icon: "plus.rectangle.on.rectangle",
            isEnabled: { !$0.isEditingText },
            run: { $0.tabs.open($0.browser.pane.path, activate: true) }
        ),
        AppCommand(
            id: .closeTab,
            title: "Закрыть вкладку",
            shortcut: Shortcut(.character("w"), .command),
            icon: "xmark",
            // На единственной вкладке команда гаснет: у приложения одно окно, и
            // закрыть его этим шорткатом значило бы оставить пользователя с
            // пустым значком в Dock без очевидного способа вернуться.
            isEnabled: { !$0.isEditingText && $0.tabs.canCloseActive },
            run: { $0.tabs.closeActive() }
        ),
        AppCommand(
            id: .nextTab,
            title: "Следующая вкладка",
            shortcut: Shortcut(.tab, .control),
            icon: nil,
            // При вводе текста не гасится, в отличие от создания и закрытия:
            // переход на другую вкладку ничего не разрушает, а прервать им
            // набор имени — законное желание.
            isEnabled: { $0.tabs.tabs.count > 1 },
            run: { $0.tabs.selectNext() }
        ),
        AppCommand(
            id: .previousTab,
            title: "Предыдущая вкладка",
            shortcut: Shortcut(.tab, [.control, .shift]),
            icon: nil,
            isEnabled: { $0.tabs.tabs.count > 1 },
            run: { $0.tabs.selectPrevious() }
        ),
        AppCommand(
            id: .openInNewTab,
            title: "Открыть в новой вкладке",
            // Без шортката: пункт живёт только в контекстном меню и работает от
            // clickedRow, а не от выделения — как остальные пункты этого меню.
            shortcut: nil,
            icon: "plus.rectangle.on.rectangle",
            isEnabled: { !$0.isEditingText && $0.browser.commandFolder != $0.browser.pane.path },
            run: { $0.tabs.open($0.browser.commandFolder, activate: true) }
        ),
    ]

    private static let table: [CommandID: AppCommand] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}
