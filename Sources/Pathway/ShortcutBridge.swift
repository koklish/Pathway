import AppKit
import PathwayCore
import SwiftUI

/// Преобразование Shortcut из PathwayCore в представления SwiftUI и AppKit.
/// Ядро не знает про UI-фреймворки, поэтому мост живёт здесь.
extension Shortcut {
    var swiftUIKey: KeyEquivalent {
        switch key {
        case .character(let character): KeyEquivalent(character)
        case .upArrow: .upArrow
        case .downArrow: .downArrow
        case .delete: .delete
        // KeyEquivalent строится из символа Unicode; для функциональных клавиш
        // это приватная область, где живут NSF*FunctionKey.
        case .f2: KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!))
        case .tab: KeyEquivalent(Character(UnicodeScalar(NSTabCharacter)!))
        }
    }

    var swiftUIModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    /// Строка keyEquivalent для NSMenuItem.
    var appKitKey: String {
        switch key {
        case .character(let character): String(character)
        case .upArrow: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case .downArrow: String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case .delete: String(UnicodeScalar(NSBackspaceCharacter)!)
        case .f2: String(UnicodeScalar(NSF2FunctionKey)!)
        case .tab: String(UnicodeScalar(NSTabCharacter)!)
        }
    }

    var appKitModifiers: NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }
}

extension AppCommand {
    /// Иконка пункта меню. NSImage строится здесь же, чтобы реестр оставался
    /// описанием, не зависящим от AppKit.
    @MainActor
    var menuImage: NSImage? {
        if id == .openClaude { return MenuIcon.claude }
        guard let icon else { return nil }
        return MenuIcon.symbol(icon, menuIconColor)
    }

    /// Цвет иконки: разрушающее действие красное, созидательное и навигация —
    /// синие, избранное — жёлтое, остальное нейтральное.
    private var menuIconColor: NSColor {
        switch id {
        case .moveToTrash: .systemRed
        case .newFolder, .open, .extractHere, .newTab, .openInNewTab: .systemBlue
        case .toggleFavorite: .systemYellow
        default: .secondaryLabelColor
        }
    }
}

/// Вешает шорткат команды на пункт меню; без шортката оставляет пункт как есть.
struct ShortcutModifier: ViewModifier {
    let shortcut: Shortcut?

    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(shortcut.swiftUIKey, modifiers: shortcut.swiftUIModifiers)
        } else {
            content
        }
    }
}
