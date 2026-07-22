import PathwayCore
import SwiftUI

/// Диалог «Подключение к серверу»: адрес и избранное, затем — авторизация.
struct ConnectServerView: View {
    let model: ConnectServerModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            switch model.step {
            case .address:
                addressStep
            case .shares(let host):
                sharesStep(host: host)
            case .credentials:
                credentialsStep
            case .editing:
                editingStep
            }

            if let notice = model.noticeMessage {
                noticeBanner(notice)
            }

            if let error = model.errorMessage {
                errorBanner(error)
            }

            footer
        }
        .padding(28)
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 20, weight: .bold))

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 20)
    }

    private var title: String {
        model.isEditing ? "Настройки подключения" : "Подключение к серверу"
    }

    private var subtitle: String {
        if model.isEditing {
            return "Как подключаться к \(model.authenticatingHost ?? "серверу")"
        }
        if model.isChoosingShare {
            return "Выберите папку на \(model.authenticatingHost ?? "сервере")"
        }
        if let host = model.authenticatingHost {
            return "Авторизация на \(host)"
        }
        return "Введите адрес сервера, чтобы подключить сетевой диск"
    }

    // MARK: - Шаг 1: адрес

    private var addressStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Адрес сервера")

                TextField(#"\\samba.ip.pro\share или smb://server/share"#, text: Binding(
                    get: { model.addressText },
                    set: { model.addressText = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(roundedField(focused: true))
                .onSubmit(submit)
            }

            if !model.bookmarks.items.isEmpty {
                bookmarksList
            }
        }
    }

    private var bookmarksList: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Избранные серверы")

            VStack(spacing: 0) {
                ForEach(Array(model.bookmarks.items.enumerated()), id: \.element.id) { index, bookmark in
                    if index > 0 { Divider() }
                    BookmarkRow(bookmark: bookmark) { model.selectBookmark(bookmark) }
                }
            }
            .background(roundedField(focused: false))
        }
    }

    // MARK: - Шаг выбора папки на сервере

    private func sharesStep(host: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Папки на сервере")

                if model.shares.isEmpty {
                    Text("Сервер не показал ни одной папки.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.shares.enumerated()), id: \.element.id) { index, share in
                            if index > 0 { Divider() }
                            ShareRow(share: share) {
                                Task { await model.selectShare(share, host: host) }
                            }
                        }
                    }
                    .background(roundedField(focused: false))
                }
            }

            Text("Папку, требующую пароль, сервер может не показать. Тогда введите её адрес вручную на предыдущем шаге.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Шаг 2: авторизация

    private var credentialsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            loginFields
        }
    }

    // MARK: - Шаг 3: настройки сохранённого сервера

    private var editingStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Адрес сервера")

                TextField(#"\\samba.ip.pro\share или smb://server/share"#, text: Binding(
                    get: { model.addressText },
                    set: { model.addressText = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(roundedField(focused: false))
                .onSubmit(submit)
            }

            loginFields

            if model.isEditingMountedServer {
                Text("Сервер подключён — изменения применятся при следующем подключении.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Общие поля входа: переключатель, логин, пароль, «Запомнить».
    @ViewBuilder
    private var loginFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Вход")
            loginPicker
        }

        if model.login == .registered {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Имя пользователя")
                TextField(#"имя пользователя или DOMAIN\пользователь"#, text: Binding(
                    get: { model.username }, set: { model.username = $0 }
                ))
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(roundedField(focused: false))
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Пароль")
                PasswordField(
                    password: Binding(get: { model.password }, set: { model.password = $0 }),
                    // Сохранённый пароль в поле не показываем: незачем лишний раз его светить.
                    placeholder: model.hasStoredPassword ? "сохранён — оставьте пустым" : "пароль",
                    onSubmit: submit
                )
            }

            Toggle(isOn: Binding(
                get: { model.saveToKeychain }, set: { model.saveToKeychain = $0 }
            )) {
                Text("Запомнить пароль в Связке ключей")
                    .font(.system(size: 13))
            }
            .toggleStyle(.checkbox)
        }
    }

    /// Сегментированный переключатель «Гость / Зарегистрированный пользователь».
    private var loginPicker: some View {
        HStack(spacing: 0) {
            ForEach(ConnectServerModel.Login.allCases, id: \.self) { option in
                let isSelected = model.login == option
                Button {
                    model.login = option
                } label: {
                    Text(option.label)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .padding(.horizontal, 14)
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
        .background(roundedField(focused: false))
    }

    // MARK: - Общие элементы

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
    }

    private func roundedField(focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        focused ? Color.accentColor : Color.primary.opacity(0.15),
                        lineWidth: focused ? 2 : 1
                    )
            }
    }

    /// Подсказка: почему снова спрашивают пароль. Не ошибка — рангом ниже.
    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
        .padding(.top, 16)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .padding(.top, 16)
    }

    private var backTitle: String {
        switch model.step {
        case .address, .editing: "Отмена"
        case .shares, .credentials: "Назад"
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()

            Button(backTitle) {
                switch model.step {
                case .address, .editing: dismiss()
                case .shares, .credentials: model.goBackToAddress()
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .keyboardShortcut(.cancelAction)

            Button(action: submit) {
                HStack(spacing: 6) {
                    if model.isConnecting || model.isLoadingShares {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(model.submitTitle)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(model.canSubmit ? Color.accentColor : Color.accentColor.opacity(0.5))
                }
            }
            .buttonStyle(.plain)
            .disabled(!model.canSubmit)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 24)
    }

    private func submit() {
        guard model.canSubmit else { return }
        Task { await model.submit() }
    }
}

/// Строка папки на сервере: имя и описание, если сервер его дал.
private struct ShareRow: View {
    let share: Share
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text(share.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let comment = share.comment {
                        Text(comment)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isHovering ? Color.primary.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Строка избранного сервера: имя слева, адрес моноширинным справа.
private struct BookmarkRow: View {
    let bookmark: ServerBookmark
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                Text(bookmark.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 12)

                Text(bookmark.address.removingPercentEncoding ?? bookmark.address)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isHovering ? Color.primary.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Поле пароля с кнопкой показа — как на макете.
private struct PasswordField: View {
    @Binding var password: String
    var placeholder = "пароль"
    let onSubmit: () -> Void

    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $password)
                } else {
                    SecureField(placeholder, text: $password)
                }
            }
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
            .onSubmit(onSubmit)

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye" : "eye.slash")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isRevealed ? "Скрыть пароль" : "Показать пароль")
        }
    }
}
