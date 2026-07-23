import AppKit
import PathwayCore
import SwiftUI

/// Сайдбар: Избранное, Места (с деревом папок), Сеть, Метки.
struct SidebarView: View {
    let model: BrowserModel
    let connection: ServerConnection
    let actions: FolderActions
    let onNewConnection: () -> Void
    let onEditServer: (ServerAddress) -> Void
    @State private var sidebar = SidebarModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                FavoritesSection(model: model, actions: actions)

                ForEach(sidebar.sections) { section in
                    SectionHeader(title: section.title)

                    ForEach(section.items) { item in
                        if item.kind == .place, item.url.path == "/" {
                            // «Этот Mac» — корень дерева папок.
                            TreeNode(url: item.url, name: item.name, depth: 0, model: model, sidebar: sidebar, actions: actions)
                        } else if item.kind == .place {
                            TreeNode(url: item.url, name: item.name, depth: 0, model: model, sidebar: sidebar, actions: actions, icon: item.systemImage)
                        } else {
                            SidebarRow(item: item, model: model)
                        }
                    }

                    // «Сеть» живёт между «Местами» и «Метками» — она строится из закладок,
                    // поэтому вставляется здесь, а не приходит из SidebarModel.
                    if section.title == "МЕСТА" {
                        SectionHeader(title: "СЕТЬ")
                        NetworkSection(
                            model: model,
                            connection: connection,
                            sidebar: sidebar,
                            onNewConnection: onNewConnection,
                            onEditSettings: onEditServer
                        )
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .scrollContentBackground(.hidden)
        .background(.regularMaterial)
        .onAppear { sidebar.reveal(model.pane.path) }
        .onChange(of: model.pane.path) { _, path in sidebar.reveal(path) }
    }
}

/// Секция «Избранное»: закреплённые папки с перетаскиванием и удалением.
private struct FavoritesSection: View {
    let model: BrowserModel
    let actions: FolderActions
    /// Индекс строки, перед которой встанет перетаскиваемый пункт.
    @State private var insertionIndex: Int?

    private var favorites: [Favorite] { actions.favorites.items }

    var body: some View {
        SectionHeader(title: "ИЗБРАННОЕ")

        if favorites.isEmpty {
            Text("Перетащите сюда папку")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        }

        ForEach(Array(favorites.enumerated()), id: \.element.id) { index, favorite in
            FavoriteRow(
                favorite: favorite,
                index: index,
                model: model,
                actions: actions,
                insertionIndex: $insertionIndex
            )
        }

        // Зона под последним пунктом: бросок сюда добавляет папку в конец списка.
        Color.clear
            .frame(height: 10)
            .contentShape(Rectangle())
            .overlay(alignment: .top) { insertionLine(at: favorites.count) }
            .dropDestination(for: URL.self) { urls, _ in
                addFolders(urls, at: favorites.count)
            } isTargeted: { targeted in
                insertionIndex = targeted ? favorites.count : nil
            }
    }

    @ViewBuilder
    private func insertionLine(at index: Int) -> some View {
        if insertionIndex == index {
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 10)
        }
    }

    private func addFolders(_ urls: [URL], at index: Int) -> Bool {
        let folders = urls.filter(\.isDirectoryOnDisk)
        guard !folders.isEmpty else { return false }
        // Вставляем в обратном порядке: каждая следующая встаёт перед предыдущей,
        // и группа сохраняет исходный порядок.
        for url in folders.reversed() {
            actions.favorites.add(url, at: index)
        }
        return true
    }
}

/// Строка «Избранного»: переход, контекстное меню, drop файлов и перестановка.
private struct FavoriteRow: View {
    let favorite: Favorite
    let index: Int
    let model: BrowserModel
    let actions: FolderActions
    @Binding var insertionIndex: Int?
    /// Подсветка, когда файлы бросают в саму папку.
    @State private var isDropTarget = false

    private var isSelected: Bool { model.pane.path.path == favorite.url.path }

    var body: some View {
        Button {
            model.navigate(to: favorite.url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "pin")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(favorite.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground)
        .padding(.horizontal, 6)
        .overlay(alignment: .top) { insertionLine }
        // Перетаскивание самой строки — для перестановки внутри секции.
        .draggable(FavoriteTransfer(id: favorite.id.uuidString, path: favorite.url.path)) {
            Label(favorite.name, systemImage: "pin")
        }
        .dropDestination(for: DroppedItem.self) { items, _ in
            handleDrop(items)
        } isTargeted: { targeted in
            // Пункт избранного — цель и для файлов, и для перестановки.
            // Что именно подсветить, решаем по содержимому перетаскивания.
            isDropTarget = targeted
            insertionIndex = targeted ? nil : insertionIndex
        }
        .contextMenu {
            FolderMenuItems(folder: favorite.url, actions: actions, model: model)
            Divider()
            Button {
                actions.favorites.remove(favorite.id)
            } label: {
                MenuLabel("Убрать из избранного", symbol: "star.slash", color: .systemYellow)
            }
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isDropTarget {
            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.35))
        } else if isSelected {
            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18))
        }
    }

    @ViewBuilder
    private var insertionLine: some View {
        if insertionIndex == index {
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 10)
        }
    }

    /// Бросок на пункт избранного: перестановка, если тащат сам пункт,
    /// иначе — перемещение файлов в эту папку.
    private func handleDrop(_ items: [DroppedItem]) -> Bool {
        let moved = items.compactMap(\.favorite)
        if !moved.isEmpty {
            reorder(moved)
            return true
        }
        let urls = items.compactMap(\.url)
        guard !urls.isEmpty else { return false }
        model.move(urls, to: favorite.url)
        return true
    }

    private func reorder(_ transfers: [FavoriteTransfer]) {
        let ids = Set(transfers.compactMap { UUID(uuidString: $0.id) })
        let offsets = IndexSet(
            actions.favorites.items.indices.filter { ids.contains(actions.favorites.items[$0].id) }
        )
        guard !offsets.isEmpty else { return }
        actions.favorites.move(fromOffsets: offsets, toOffset: index)
    }
}

/// Заголовок секции: мелкие заглавные буквы, как в макете.
private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .kerning(0.6)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }
}

/// Обычная строка сайдбара: сеть, метка.
private struct SidebarRow: View {
    let item: SidebarItem
    let model: BrowserModel

    var body: some View {
        Button {
            switch item.kind {
            case .favorite: model.navigate(to: item.url)
            case .place, .tag, .network: break
            }
        } label: {
            HStack(spacing: 8) {
                icon
                Text(item.name)
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
    }

    @ViewBuilder
    private var icon: some View {
        if let color = item.tagColor {
            Circle()
                .fill(Color(tag: color))
                .frame(width: 10, height: 10)
                .frame(width: 16)
        } else {
            Image(systemName: item.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(item.kind == .favorite ? .secondary : Color.accentColor)
                .frame(width: 16)
        }
    }
}

/// Узел дерева папок: стрелка раскрытия, иконка, название; дети читаются лениво.
struct TreeNode: View {
    let url: URL
    let name: String
    let depth: Int
    let model: BrowserModel
    let sidebar: SidebarModel
    var actions: FolderActions?
    var icon: String = "folder"

    @State private var children: [FileItem] = []
    @State private var isDropTarget = false

    private var isExpanded: Bool { sidebar.isExpanded(url) }
    private var isSelected: Bool { model.pane.path.path == url.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if isExpanded {
                ForEach(children) { child in
                    TreeNode(url: child.url, name: child.name, depth: depth + 1, model: model, sidebar: sidebar, actions: actions)
                }
            }
        }
        .task(id: isExpanded) { await loadChildrenIfNeeded() }
    }

    private var row: some View {
        HStack(spacing: 4) {
            Button {
                sidebar.toggleExpansion(url)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    // Кликабельная зона больше самой стрелки: попадать по глифу неудобно.
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(children.isEmpty && !isExpanded ? 0.35 : 1)

            Button {
                model.navigate(to: url)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                    Text(name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(depth) * 14 + 8)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(background)
        .padding(.horizontal, 6)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            model.move(urls, to: url)
            return true
        } isTargeted: { isDropTarget = $0 }
        .contextMenu {
            if let actions {
                FolderMenuItems(folder: url, actions: actions, model: model)
                Divider()
                let isFavorite = actions.isFavorite(url)
                Button {
                    actions.toggleFavorite(url)
                } label: {
                    MenuLabel(
                        isFavorite ? "Убрать из избранного" : "Добавить в избранное",
                        symbol: isFavorite ? "star.slash" : "star",
                        color: .systemYellow
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        if isDropTarget {
            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.35))
        } else if isSelected {
            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18))
        }
    }

    private func loadChildrenIfNeeded() async {
        guard isExpanded, children.isEmpty else { return }
        children = await model.subdirectoriesAsync(of: url)
    }
}

/// Пункты меню, общие для сайдбара и списка файлов.
struct FolderMenuItems: View {
    let folder: URL
    let actions: FolderActions
    let model: BrowserModel
    /// Вкладки — из окружения: пункт нужен во всех меню сайдбара, а тянуть
    /// параметр через FavoritesSection и TreeNode значило бы править пять
    /// уровней вью ради одной кнопки.
    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            appState.tabs.open(folder, activate: true)
        } label: {
            MenuLabel("Открыть в новой вкладке", symbol: "plus.rectangle.on.rectangle", color: .systemBlue)
        }
        Divider()
        Button {
            actions.openTerminal(at: folder)
        } label: {
            MenuLabel("Открыть в Терминале", symbol: "terminal")
        }
        if actions.isClaudeAvailable {
            Button {
                actions.openClaude(at: folder)
            } label: {
                MenuLabel("Открыть в Claude Code", image: MenuIcon.claude)
            }
        }
        Divider()
        Button {
            actions.revealInFinder(folder)
        } label: {
            MenuLabel("Показать в Finder", symbol: "macwindow")
        }
    }
}

/// Пункт меню с иконкой.
///
/// SwiftUI показывает символ в `Label` монохромным и игнорирует `foregroundStyle`
/// внутри меню, поэтому цветные и не-символьные иконки (например, у Claude)
/// готовятся как NSImage и отдаются через `Image(nsImage:)`.
struct MenuLabel: View {
    let title: String
    let image: NSImage?

    init(_ title: String, image: NSImage?) {
        self.title = title
        self.image = image
    }

    init(_ title: String, symbol: String, color: NSColor = .secondaryLabelColor) {
        self.init(title, image: MenuIcon.symbol(symbol, color))
    }

    var body: some View {
        if let image {
            Label { Text(title) } icon: { Image(nsImage: image) }
        } else {
            Text(title)
        }
    }
}

extension URL {
    /// Существующая на диске папка. Нужно, чтобы в избранное не попал файл.
    var isDirectoryOnDisk: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

private extension Color {
    init(tag: SidebarItem.TagColor) {
        switch tag {
        case .red: self = .red
        case .orange: self = .orange
        case .yellow: self = .yellow
        case .green: self = .green
        case .blue: self = .blue
        case .purple: self = .purple
        case .gray: self = .gray
        }
    }
}
