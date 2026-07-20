import PathwayCore
import SwiftUI

/// Сайдбар: Избранное, Места (с деревом папок), Сеть, Метки.
struct SidebarView: View {
    let model: BrowserModel
    @State private var sidebar = SidebarModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sidebar.sections) { section in
                    SectionHeader(title: section.title)

                    ForEach(section.items) { item in
                        if item.kind == .place, item.url.path == "/" {
                            // «Этот Mac» — корень дерева папок.
                            TreeNode(url: item.url, name: item.name, depth: 0, model: model, sidebar: sidebar)
                        } else if item.kind == .place {
                            TreeNode(url: item.url, name: item.name, depth: 0, model: model, sidebar: sidebar, icon: item.systemImage)
                        } else {
                            SidebarRow(item: item, model: model)
                        }
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

/// Обычная строка сайдбара: избранное, сеть, метка.
private struct SidebarRow: View {
    let item: SidebarItem
    let model: BrowserModel

    private var isSelected: Bool {
        item.kind == .favorite && model.pane.path.path == item.url.path
    }

    var body: some View {
        Button {
            guard item.kind == .favorite else { return }
            model.navigate(to: item.url)
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
        .background(selectionBackground)
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

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18))
        }
    }
}

/// Узел дерева папок: стрелка раскрытия, иконка, название; дети читаются лениво.
private struct TreeNode: View {
    let url: URL
    let name: String
    let depth: Int
    let model: BrowserModel
    let sidebar: SidebarModel
    var icon: String = "folder"

    @State private var children: [FileItem] = []

    private var isExpanded: Bool { sidebar.isExpanded(url) }
    private var isSelected: Bool { model.pane.path.path == url.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if isExpanded {
                ForEach(children) { child in
                    TreeNode(url: child.url, name: child.name, depth: depth + 1, model: model, sidebar: sidebar)
                }
            }
        }
        .onAppear(perform: loadChildrenIfNeeded)
        .onChange(of: isExpanded) { _, _ in loadChildrenIfNeeded() }
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
                    .frame(width: 12, height: 12)
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
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18))
            }
        }
        .padding(.horizontal, 6)
    }

    private func loadChildrenIfNeeded() {
        guard isExpanded, children.isEmpty else { return }
        children = model.subdirectories(of: url)
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
