import PathwayCore
import SwiftUI

/// Адресная строка: кнопки навигации и поле пути, которое переключается
/// между хлебными крошками и вводом текста (как в Проводнике Windows).
struct AddressBarView: View {
    let model: BrowserModel

    @State private var isEditing = false
    @State private var pathText = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            navigationButtons
            pathControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: model.pane.path) { _, _ in isEditing = false }
    }

    private var navigationButtons: some View {
        HStack(spacing: 2) {
            Button { model.pane.goBack(); model.reload() } label: { NavIcon("chevron.left") }
                .disabled(!model.pane.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help("Назад (⌘[)")

            Button { model.pane.goForward(); model.reload() } label: { NavIcon("chevron.right") }
                .disabled(!model.pane.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .help("Вперёд (⌘])")

            Button { model.pane.goUp(); model.reload() } label: { NavIcon("chevron.up") }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .help("Вверх (⌘↑)")

            Button { model.reload() } label: { NavIcon("arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
                .help("Обновить (⌘R)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
    }

    /// Поле пути: рамка одна и та же в обоих режимах, меняется только начинка.
    private var pathControl: some View {
        HStack(spacing: 6) {
            if isEditing {
                pathField
            } else {
                breadcrumbs
                editButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(height: 30)
        .background(fieldBackground)
        .background {
            // ⌘L переводит строку в режим ввода, даже когда фокус в списке файлов.
            Button("") { beginEditing() }
                .keyboardShortcut("l", modifiers: .command)
                .opacity(0)
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isEditing ? Color.accentColor : Color.primary.opacity(0.12),
                        lineWidth: isEditing ? 2 : 1
                    )
            }
    }

    private var pathField: some View {
        TextField("Путь", text: $pathText)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .focused($fieldFocused)
            .onSubmit(commitEditing)
            .onExitCommand { isEditing = false }
            // Клик мимо поля — куда угодно: в список, в сайдбар, в пустое место —
            // должен закрывать ввод. Правку при этом отбрасываем: пользователь
            // ушёл, не подтвердив её, а неявная навигация была бы неожиданной.
            .onChange(of: fieldFocused) { _, focused in
                if !focused { isEditing = false }
            }
            .onAppear {
                fieldFocused = true
                // SwiftUI ставит курсор в конец; макет требует выделения всего пути.
                DispatchQueue.main.async {
                    NSApp.keyWindow?.firstResponder.flatMap { $0 as? NSText }?.selectAll(nil)
                }
            }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 2) {
            ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.url) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 2)
                }
                CrumbButton(
                    crumb: crumb,
                    isLast: index == model.breadcrumbs.count - 1,
                    isRoot: index == 0
                ) {
                    model.navigate(to: crumb.url)
                }
            }

            // Пустое место справа от крошек — тоже вход в режим ввода, как в Проводнике.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { beginEditing() }
        }
    }

    private var editButton: some View {
        Button(action: beginEditing) {
            Image(systemName: "pencil")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Редактировать путь (⌘L)")
    }

    private func beginEditing() {
        // Для сетевой шары показываем UNC: именно этот путь открывается у коллег
        // в Windows, а локальный /Volumes/… осмыслен только на этой машине.
        pathText = NetworkPath.display(for: model.pane.path)
        isEditing = true
    }

    private func commitEditing() {
        let trimmed = pathText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { isEditing = false; return }
        guard let target = PathInput.resolve(trimmed) else {
            // Сетевой адрес введён, но том не подключён — молча ничего не делать
            // хуже, чем сказать, в чём дело.
            model.errorMessage = "Сетевая папка «\(trimmed)» не подключена. Подключите сервер в секции «Сеть», затем повторите."
            isEditing = false
            return
        }
        model.navigate(to: target)
        isEditing = false
    }
}

/// Иконка кнопки навигации в невидимом квадрате 24×24: попадать по тонкому глифу
/// шеврона мышью неудобно, зона клика должна быть заметно больше рисунка.
private struct NavIcon: View {
    let name: String

    init(_ name: String) { self.name = name }

    var body: some View {
        Image(systemName: name)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }
}

/// Один сегмент пути. Подсвечивается под курсором, чтобы кликабельность была очевидна.
private struct CrumbButton: View {
    let crumb: Breadcrumb
    let isLast: Bool
    let isRoot: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isRoot {
                    Image(systemName: "house")
                        .font(.system(size: 11))
                }
                Text(crumb.name)
                    .font(.system(size: 13, weight: isLast ? .medium : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isLast ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering ? Color.primary.opacity(0.07) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(crumb.url.path)
    }
}
