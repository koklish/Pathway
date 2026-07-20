import PathwayCore
import SwiftUI

/// Сайдбар: избранное и дерево папок с ленивой подгрузкой.
struct SidebarView: View {
    @Environment(AppState.self) private var appState
    let model: BrowserModel

    var body: some View {
        List(selection: Binding(get: { model.pane.path }, set: { if let url = $0 { model.navigate(to: url) } })) {
            Section("Избранное") {
                ForEach(appState.favorites) { favorite in
                    Label(favorite.name, systemImage: favorite.systemImage)
                        .tag(favorite.url)
                }
            }

            Section("Этот Mac") {
                DirectoryTreeNode(url: URL(fileURLWithPath: "/"), name: "Macintosh HD", model: model)
            }
        }
        .listStyle(.sidebar)
    }
}

/// Узел дерева: раскрывается по стрелке, дети читаются только при раскрытии.
private struct DirectoryTreeNode: View {
    let url: URL
    let name: String
    let model: BrowserModel

    @State private var isExpanded = false
    @State private var children: [FileItem] = []

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(children) { child in
                DirectoryTreeNode(url: child.url, name: child.name, model: model)
            }
        } label: {
            Label(name, systemImage: "folder")
                .tag(url)
                .onTapGesture { model.navigate(to: url) }
        }
        .onChange(of: isExpanded) { _, expanded in
            guard expanded, children.isEmpty else { return }
            children = model.subdirectories(of: url)
        }
    }
}
