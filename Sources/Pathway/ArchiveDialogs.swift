import PathwayCore
import SwiftUI

/// Диалог «Архивировать»: имя архива, формат и пароль (только для ZIP).
struct CompressDialogView: View {
    let model: BrowserModel
    let items: [FileItem]
    let dismiss: () -> Void

    @State private var name: String
    @State private var format: ArchiveFormat = .zip
    @State private var password = ""
    @State private var confirmation = ""

    init(model: BrowserModel, items: [FileItem], dismiss: @escaping () -> Void) {
        self.model = model
        self.items = items
        self.dismiss = dismiss
        _name = State(initialValue: Self.defaultName(for: items))
    }

    /// Имя по умолчанию — как в Finder: имя единственного объекта или «Архив».
    private static func defaultName(for items: [FileItem]) -> String {
        guard items.count == 1, let item = items.first else { return "Архив" }
        if item.isDirectory { return item.name }
        let base = item.url.deletingPathExtension().lastPathComponent
        return base.isEmpty ? item.name : base
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Архивировать")
                    .font(.system(size: 20, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Имя архива")
                    TextField("Архив", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(roundedField)
                        .onSubmit(submit)
                }

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Формат")
                    formatPicker
                }

                if format.supportsPassword {
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Пароль")
                        SecureField("не задан — архив без пароля", text: $password)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(roundedField)
                    }

                    if !password.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("Подтверждение пароля")
                            SecureField("ещё раз", text: $confirmation)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(roundedField)
                                .onSubmit(submit)
                        }

                        if !confirmation.isEmpty && password != confirmation {
                            Text("Пароли не совпадают.")
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    Text("Пароль поддерживает только формат ZIP.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            footer
        }
        .padding(28)
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var subtitle: String {
        if items.count == 1, let item = items.first {
            return "«\(item.name)» — в архив рядом с оригиналом"
        }
        return "Объектов: \(items.count) — в один архив рядом с оригиналами"
    }

    private var formatPicker: some View {
        HStack(spacing: 0) {
            ForEach(ArchiveFormat.allCases, id: \.self) { option in
                let isSelected = format == option
                Button {
                    format = option
                } label: {
                    Text(option.displayName)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(isSelected ? Color.accentColor : .clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(roundedField)
    }

    private var canSubmit: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":") else { return false }
        if format.supportsPassword && !password.isEmpty {
            return password == confirmation
        }
        return true
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()

            Button("Отмена", action: dismiss)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .keyboardShortcut(.cancelAction)

            Button(action: submit) {
                Text("Создать")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(canSubmit ? Color.accentColor : Color.accentColor.opacity(0.5))
                    }
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 24)
    }

    private func submit() {
        guard canSubmit else { return }
        let effectivePassword = format.supportsPassword && !password.isEmpty ? password : nil
        model.compress(
            items: items,
            format: format,
            password: effectivePassword,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        dismiss()
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
    }

    private var roundedField: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
            }
    }
}

/// Запрос пароля при распаковке зашифрованного архива.
struct ExtractPasswordView: View {
    let model: BrowserModel
    let request: PasswordRequest

    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Архив защищён паролем")
                    .font(.system(size: 20, weight: .bold))
                Text("Введите пароль для «\(request.archive.lastPathComponent)»")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 20)

            SecureField("пароль", text: $password)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                        }
                }
                .onSubmit(submit)

            if request.wasWrong {
                Text("Неверный пароль. Попробуйте ещё раз.")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.top, 8)
            }

            HStack(spacing: 12) {
                Spacer()

                Button("Отмена") { model.cancelPasswordRequest() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .keyboardShortcut(.cancelAction)

                Button(action: submit) {
                    Text("Распаковать")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(password.isEmpty ? Color.accentColor.opacity(0.5) : Color.accentColor)
                        }
                }
                .buttonStyle(.plain)
                .disabled(password.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24)
        }
        .padding(28)
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func submit() {
        guard !password.isEmpty else { return }
        model.submitPassword(password)
    }
}
