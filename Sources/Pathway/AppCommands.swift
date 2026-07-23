import PathwayCore
import SwiftUI

/// Главное меню приложения. Пункты строятся из CommandRegistry, поэтому
/// заголовок, иконка, шорткат и доступность описаны ровно в одном месте.
struct AppCommands: Commands {
    let state: AppState
    let updates: UpdateService

    var body: some Commands {
        // Рядом с «О программе» — там этот пункт ищут по традиции macOS.
        // Шорткат не нужен: проверка обновлений не входит в частый обиход.
        CommandGroup(after: .appInfo) {
            Button("Проверить обновления…") {
                Task { await updates.checkManually() }
            }
        }

        CommandGroup(replacing: .newItem) {
            item(.newTab)
            item(.closeTab)
            Divider()
            item(.newFolder)
            Divider()
            item(.open)
            item(.rename)
            Divider()
            item(.compress)
            item(.extractHere)
            Divider()
            item(.revealInFinder)
            item(.openTerminal)
            item(.openClaude)
        }

        // Группа .pasteboard намеренно не заменяется: её стандартные пункты
        // несут селекторы copy:/cut:/paste:/selectAll: с target = nil, и
        // AppKit сам доставляет их по responder chain — в текстовом поле
        // работает текстовая операция, в списке файловая. Свой Button с
        // замыканием держит жёсткий target, поэтому он перехватывал бы ⌘C и
        // до NSTextField клавиша не доходила: в диалогах не работали ни
        // копирование, ни вставка.
        //
        // Файловую сторону реализует FileListView.Coordinator — он first
        // responder, когда фокус в списке.
        CommandGroup(after: .pasteboard) {
            Divider()
            item(.moveToTrash)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            hiddenFilesToggle
            item(.refresh)
        }

        CommandMenu("Переход") {
            item(.goBack)
            item(.goForward)
            item(.goUp)
            Divider()
            item(.editPath)
            Divider()
            item(.nextTab)
            item(.previousTab)
            Divider()
            item(.toggleFavorite)
        }
    }

    private func item(_ id: CommandID) -> some View {
        let command = CommandRegistry[id]
        return Button(title(for: command)) { command.run(state) }
            .disabled(!command.isEnabled(state))
            .modifier(ShortcutModifier(shortcut: command.shortcut))
    }

    /// Пункт-переключатель: галочка показывает текущее состояние, поэтому
    /// заголовок остаётся утвердительным, а не меняется на «Скрыть…».
    private var hiddenFilesToggle: some View {
        let command = CommandRegistry[.toggleHiddenFiles]
        return Toggle(command.title, isOn: Binding(
            get: { state.showHiddenFiles },
            set: { _ in command.run(state) }
        ))
        .modifier(ShortcutModifier(shortcut: command.shortcut))
    }

    /// Заголовок избранного зависит от того, закреплена ли папка, — как в
    /// контекстном меню.
    private func title(for command: AppCommand) -> String {
        guard command.id == .toggleFavorite else { return command.title }
        return state.folderActions.isFavorite(state.browser.commandFolder)
            ? "Убрать из избранного"
            : "Добавить в избранное"
    }
}
