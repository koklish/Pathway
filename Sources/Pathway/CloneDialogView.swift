import PathwayCore
import SwiftUI

/// Диалог «Клонировать репозиторий»: адрес и имя папки.
struct CloneDialogView: View {
    let model: BrowserModel
    let destination: URL
    let dismiss: () -> Void

    @State private var url = ""
    @State private var name = ""
    /// Имя правил руками — подстановка из адреса больше не вмешивается.
    @State private var nameEdited = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Клонировать репозиторий")
                    .font(.system(size: 20, weight: .bold))
                Text("В папку «\(destination.lastPathComponent)»")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Адрес репозитория")
                    TextField("https://github.com/user/repo.git", text: $url)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(roundedField)
                        .onSubmit(submit)
                        // Имя подставляется из адреса, пока его не правили
                        // руками: иначе набранное имя затиралось бы при каждой
                        // правке адреса.
                        .onChange(of: url) { _, newValue in
                            guard !nameEdited else { return }
                            name = GitService.suggestedName(for: newValue) ?? ""
                        }
                }

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Имя папки")
                    TextField("как в адресе", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(roundedField)
                        .onSubmit(submit)
                        .onChange(of: name) { _, _ in
                            // Совпадение с подстановкой правкой не считается:
                            // иначе автоподстановка сама себя и отключила бы.
                            if name != (GitService.suggestedName(for: url) ?? "") { nameEdited = true }
                        }
                }

                if exists {
                    Text("Папка «\(trimmedName)» уже есть — выберите другое имя.")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }

            footer
        }
        .padding(28)
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Занятость имени проверяется до запуска: git упал бы с «destination path
    /// already exists», и человек узнал бы об этом только из алерта.
    private var exists: Bool {
        guard !trimmedName.isEmpty else { return false }
        return FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(trimmedName).path)
    }

    private var canSubmit: Bool {
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !exists else { return false }
        return !trimmedName.contains("/") && !trimmedName.contains(":")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()

            Button("Отмена", action: dismiss)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .keyboardShortcut(.cancelAction)

            Button(action: submit) {
                Text("Клонировать")
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
        model.gitClone(from: url.trimmingCharacters(in: .whitespacesAndNewlines), name: trimmedName)
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
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
    }
}
