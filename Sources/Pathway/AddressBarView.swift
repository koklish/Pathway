import PathwayCore
import SwiftUI

/// Адресная строка: кнопки навигации, хлебные крошки и режим ввода пути (⌘L).
struct AddressBarView: View {
    let model: BrowserModel

    @State private var isEditing = false
    @State private var pathText = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            navigationButtons

            if isEditing {
                pathField
            } else {
                breadcrumbs
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: model.pane.path) { _, _ in isEditing = false }
    }

    private var navigationButtons: some View {
        HStack(spacing: 2) {
            Button { model.pane.goBack(); model.reload() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.pane.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help("Назад (⌘[)")

            Button { model.pane.goForward(); model.reload() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.pane.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .help("Вперёд (⌘])")

            Button { model.pane.goUp(); model.reload() } label: { Image(systemName: "chevron.up") }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .help("Вверх (⌘↑)")

            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
                .help("Обновить (⌘R)")
        }
        .buttonStyle(.borderless)
    }

    private var pathField: some View {
        TextField("Путь", text: $pathText)
            .textFieldStyle(.roundedBorder)
            .focused($fieldFocused)
            .onSubmit {
                model.navigate(to: URL(fileURLWithPath: (pathText as NSString).expandingTildeInPath))
                isEditing = false
            }
            .onExitCommand { isEditing = false }
            .onAppear { fieldFocused = true }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 2) {
            ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.url) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .foregroundStyle(.tertiary)
                }
                Button(crumb.name) { model.navigate(to: crumb.url) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(index == model.breadcrumbs.count - 1 ? .primary : .secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginEditing() }
        .background {
            Button("") { beginEditing() }
                .keyboardShortcut("l", modifiers: .command)
                .opacity(0)
        }
    }

    private func beginEditing() {
        pathText = model.pane.path.path
        isEditing = true
    }
}
