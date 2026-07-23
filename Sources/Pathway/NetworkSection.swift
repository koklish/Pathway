import AppKit
import PathwayCore
import SwiftUI

/// Строка секции «Сеть»: либо сохранённая закладка, либо том, найденный в системе.
struct ServerEntry: Identifiable {
    let server: ServerAddress
    let name: String
    /// Пусто у томов, смонтированных мимо приложения: удалять из списка нечего.
    let bookmark: ServerBookmark?

    var id: String { server.key }
}

/// Секция «Сеть»: сохранённые серверы и кнопка нового подключения.
struct NetworkSection: View {
    let model: BrowserModel
    let connection: ServerConnection
    let sidebar: SidebarModel
    /// Открыть диалог: новое подключение или настройки сохранённого сервера.
    let onNewConnection: () -> Void
    let onEditSettings: (ServerAddress) -> Void

    @State private var errorMessage: String?
    @State private var pendingRemoval: ServerBookmark?

    /// Что показать в секции: сохранённые закладки плюс тома, смонтированные
    /// мимо приложения — иначе такой диск исчезнет из сайдбара совсем.
    private var entries: [ServerEntry] {
        var result: [ServerEntry] = []
        // Один адрес — одна строка. Совпадение id в ForEach ломает и выделение,
        // и наведение: подсвечиваются сразу все строки с этим id.
        var seen: Set<String> = []

        for bookmark in connection.bookmarks.items {
            guard let server = bookmark.server, seen.insert(server.key).inserted else { continue }
            result.append(ServerEntry(server: server, name: bookmark.name, bookmark: bookmark))
        }
        for volume in connection.mounted.networkVolumes {
            guard seen.insert(volume.server.key).inserted else { continue }
            result.append(ServerEntry(server: volume.server, name: volume.name, bookmark: nil))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                ServerNode(
                    entry: entry,
                    model: model,
                    connection: connection,
                    sidebar: sidebar,
                    onEditSettings: { onEditSettings(entry.server) },
                    onRemove: { pendingRemoval = entry.bookmark },
                    onError: { errorMessage = $0 }
                )
            }

            Button(action: onNewConnection) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 16)
                    Text("Подключиться к серверу…")
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .onboardingTarget(.connectServer)
        }
        .alert(
            "Не удалось отключить том",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("ОК", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(
            "Удалить сервер из списка?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
        ) {
            Button("Отмена", role: .cancel) { pendingRemoval = nil }
            Button("Удалить", role: .destructive) {
                if let server = pendingRemoval?.server { connection.removeBookmark(for: server) }
                pendingRemoval = nil
            }
        } message: {
            Text("Сохранённый пароль тоже будет удалён из Связки ключей.")
        }
    }
}

/// Сервер в сайдбаре: своя строка со статусом подключения и дерево папок под ней.
///
/// Иерархия живёт здесь, а не в «Местах»: сетевой том — это прежде всего сервер,
/// и разворачивать его логично там же, где им управляют.
private struct ServerNode: View {
    let entry: ServerEntry
    let model: BrowserModel
    let connection: ServerConnection
    let sidebar: SidebarModel
    let onEditSettings: () -> Void
    let onRemove: () -> Void
    let onError: (String) -> Void

    @State private var children: [FileItem] = []

    private var mountPoint: URL? { connection.mounted.mountPoint(for: entry.server) }
    private var isExpanded: Bool {
        guard let mountPoint else { return false }
        return sidebar.isExpanded(mountPoint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ServerRow(
                entry: entry,
                model: model,
                connection: connection,
                isExpanded: isExpanded,
                hasChildren: !children.isEmpty,
                onToggleExpansion: toggleExpansion,
                onEditSettings: onEditSettings,
                onRemove: onRemove,
                onError: onError
            )

            if isExpanded {
                ForEach(children) { child in
                    TreeNode(url: child.url, name: child.name, depth: 1, model: model, sidebar: sidebar)
                }
            }
        }
        .task(id: isExpanded) { await loadChildrenIfNeeded() }
    }

    private func toggleExpansion() {
        // Раскрывать нечего, пока том не подключён: список папок брать неоткуда.
        guard let mountPoint else { return }
        sidebar.toggleExpansion(mountPoint)
    }

    private func loadChildrenIfNeeded() async {
        guard isExpanded, children.isEmpty, let mountPoint else { return }
        children = await model.subdirectoriesAsync(of: mountPoint)
    }
}

/// Строка сервера: состояние подключения, переход или подключение по клику,
/// настройки — по правой кнопке.
private struct ServerRow: View {
    let entry: ServerEntry
    let model: BrowserModel
    let connection: ServerConnection
    let isExpanded: Bool
    let hasChildren: Bool
    let onToggleExpansion: () -> Void
    let onEditSettings: () -> Void
    let onRemove: () -> Void
    let onError: (String) -> Void

    @State private var isHovering = false
    /// Наличие пароля выясняем один раз при появлении строки, а не в `body`.
    ///
    /// `body` пересобирается на каждое наведение мыши и обновление состояния, и обращение
    /// к Связке ключей оттуда превращается в поток запросов — а если система решит
    /// спросить разрешение, то и в бесконечную череду диалогов.
    @State private var hasSavedPassword = false

    private var server: ServerAddress { entry.server }

    private var isMounted: Bool { connection.mounted.isMounted(server) }
    private var isConnecting: Bool { connection.isConnecting(server) }

    private var isSelected: Bool {
        guard let point = connection.mounted.mountPoint(for: server) else { return false }
        return model.pane.path.path == point.path
    }

    var body: some View {
        HStack(spacing: 4) {
            // Стрелка только у подключённого тома: у отключённого раскрывать нечего.
            if isMounted {
                Button(action: onToggleExpansion) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
                .opacity(!hasChildren && !isExpanded ? 0.35 : 1)
            } else {
                Color.clear.frame(width: 12, height: 12)
            }

            Button(action: activate) {
                HStack(spacing: 8) {
                    icon
                    Text(entry.name)
                        .font(.system(size: 13))
                        .foregroundStyle(isMounted ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isMounted {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18))
            } else if isHovering {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05))
            }
        }
        .padding(.horizontal, 6)
        .onHover { isHovering = $0 }
        .help(server.key.removingPercentEncoding ?? server.key)
        .contextMenu { menuItems }
        .task(id: server.key) {
            hasSavedPassword = connection.hasSavedPassword(for: server)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if isConnecting {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 16)
        } else {
            Image(systemName: isMounted ? "externaldrive.fill.badge.checkmark" : "externaldrive")
                .font(.system(size: 12))
                .foregroundStyle(isMounted ? Color.accentColor : .secondary)
                .frame(width: 16)
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if isMounted {
            Button {
                openMountPoint()
            } label: {
                MenuLabel("Открыть", symbol: "arrow.up.forward.app", color: .systemBlue)
            }
            Button {
                disconnect()
            } label: {
                MenuLabel("Отключить", symbol: "eject")
            }
        } else {
            Button {
                connect()
            } label: {
                MenuLabel("Подключиться", symbol: "externaldrive.badge.plus", color: .systemBlue)
            }
        }

        Divider()

        Button(action: onEditSettings) {
            MenuLabel("Изменить настройки…", symbol: "gearshape")
        }

        // Пункт, который ничего не делает, хуже отсутствующего.
        if hasSavedPassword {
            Button {
                connection.forgetPassword(for: server)
                hasSavedPassword = false
            } label: {
                MenuLabel("Забыть пароль", symbol: "key.slash")
            }
        }

        // У тома, смонтированного мимо приложения, закладки нет — удалять нечего.
        if entry.bookmark != nil {
            Divider()
            Button(action: onRemove) {
                MenuLabel("Удалить из списка", symbol: "trash", color: .systemRed)
            }
        }
    }

    private func activate() {
        if isMounted {
            openMountPoint()
        } else {
            connect()
        }
    }

    private func openMountPoint() {
        guard let point = connection.mounted.mountPoint(for: server) else { return }
        model.navigate(to: point)
    }

    private func connect() {
        Task {
            let outcome = await connection.connect(to: server)
            switch outcome {
            case .mounted(let point):
                model.navigate(to: point)
            case .failed(let message):
                onError(message)
            case .needsCredentials:
                // Учётных данных нет или они устарели — дальше разбирается диалог.
                onEditSettings()
            }
        }
    }

    private func disconnect() {
        Task {
            if let message = await connection.disconnect(from: server) {
                onError(message)
            }
        }
    }
}
