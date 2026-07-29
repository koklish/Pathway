import AppKit
import PathwayCore
import SwiftUI

/// Иконка закладки избранного: назначенный символ, эмодзи или pin по умолчанию.
///
/// Валидность имени SF Symbol проверяется здесь, а не в Core: отвечает на неё
/// только `NSImage(systemSymbolName:)`, и тащить AppKit в PathwayCore ради
/// одной проверки значило бы нарушить границу «нет типов, которые рисуют».
struct FavoriteIcon: View {
    let icon: String?

    private var symbolName: String? {
        guard let icon, NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil
        else { return nil }
        return icon
    }

    var body: some View {
        if let symbolName {
            Image(systemName: symbolName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        } else if let icon {
            // Эмодзи или произвольный символ — рисуется текстом.
            Text(icon)
                .font(.system(size: 12))
                .frame(width: 16)
        } else {
            Image(systemName: "pin")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        }
    }
}

/// Лист выбора иконки закладки: сетка SF Symbols, поле для эмодзи, сброс.
struct FavoriteIconPicker: View {
    let favorite: Favorite
    let store: FavoritesStore
    let onClose: () -> Void

    @Environment(AppState.self) private var appState
    @State private var emoji = ""

    /// Подборка символов, осмысленных для папок. Полного каталога имён в
    /// публичном API нет, а выгрузка из SF Symbols.app — тысячи строк данных
    /// ради редкого действия.
    private static let symbols = [
        "folder", "star", "heart", "bookmark", "house", "briefcase",
        "hammer", "wrench", "photo", "music.note", "film", "gamecontroller",
        "book", "graduationcap", "airplane", "cart", "gift", "leaf",
        "flame", "bolt", "lock", "cloud", "desktopcomputer", "iphone",
    ]

    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 4), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Иконка для «\(favorite.name)»")
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    Button {
                        store.setIcon(favorite.id, icon: symbol)
                        onClose()
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 16))
                            .frame(width: 36, height: 30)
                            .background {
                                if favorite.icon == symbol {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.accentColor.opacity(0.2))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                TextField("Эмодзи или символ", text: $emoji)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit { applyEmoji() }
                Button("Выбрать") { applyEmoji() }
                    .disabled(emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack {
                Button("По умолчанию") {
                    store.setIcon(favorite.id, icon: nil)
                    onClose()
                }
                Spacer()
                Button("Готово") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
        // Лист с полем ввода: файловые шорткаты (F2, ⌘⌫) под ним гасим,
        // как и в остальных модальных листах.
        .onAppear { appState.isEditingText = true }
        .onDisappear { appState.isEditingText = false }
    }

    private func applyEmoji() {
        store.setIcon(favorite.id, icon: emoji)
        onClose()
    }
}
