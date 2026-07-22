import Foundation

/// Клавиша шортката. Собственный тип, а не KeyEquivalent из SwiftUI: PathwayCore
/// не зависит от UI-фреймворков, преобразование живёт в Sources/Pathway.
public enum ShortcutKey: Sendable, Equatable {
    case character(Character)
    case upArrow
    case downArrow
    case delete
    case f2
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

        // Буферные команды доступны и во время ввода текста: погашенный пункт
        // меню перехватывает шорткат и никуда его не отдаёт, так что ⌘C
        // переставал доходить до NSTextField и в полях диалогов не работал
        // вовсе. Живой пункт AppKit доставляет по responder chain — фокус в
        // поле берёт текстовую операцию, фокус в списке файловую.
        //
        // Защита переехала в run: responder chain стережёт только клавиши, а
        // выбор пункта мышью при открытом диалоге пришёл бы сюда напрямую.

        AppCommand(
            id: .copy,
            title: "Копировать",
            shortcut: Shortcut(.character("c"), .command),
            icon: "document.on.document",
            isEnabled: { !$0.browser.pane.selection.isEmpty },
            run: { if !$0.isEditingText { $0.browser.copy() } }
        ),
        AppCommand(
            id: .cut,
            title: "Вырезать",
            shortcut: Shortcut(.character("x"), .command),
            icon: "scissors",
            isEnabled: { !$0.browser.isReadOnlyVolume && !$0.browser.pane.selection.isEmpty },
            run: { if !$0.isEditingText { $0.browser.cut() } }
        ),
        AppCommand(
            id: .paste,
            title: "Вставить",
            shortcut: Shortcut(.character("v"), .command),
            icon: "clipboard",
            isEnabled: { !$0.browser.isReadOnlyVolume && $0.browser.canPaste },
            run: { if !$0.isEditingText { $0.browser.paste() } }
        ),
        AppCommand(
            id: .selectAll,
            title: "Выбрать всё",
            shortcut: Shortcut(.character("a"), .command),
            icon: nil,
            isEnabled: { !$0.browser.items.isEmpty },
            run: { if !$0.isEditingText { $0.browser.selectAll() } }
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
    ]

    private static let table: [CommandID: AppCommand] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}
