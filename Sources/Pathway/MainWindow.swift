import PathwayCore
import SwiftUI

/// Главное окно: сайдбар + адресная строка + список файлов + статус-бар.
struct MainWindow: View {
    @Environment(AppState.self) private var appState
    @State private var model = BrowserModel(path: FileManager.default.homeDirectoryForCurrentUser)
    @State private var renamingItem: URL?

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            VStack(spacing: 0) {
                AddressBarView(model: model)
                Divider()
                FileListView(model: model, renamingItem: $renamingItem)
                Divider()
                StatusBarView(model: model)
            }
        }
        .onAppear {
            model.showHiddenFiles = appState.showHiddenFiles
            model.reload()
        }
        .onChange(of: appState.showHiddenFiles) { _, show in
            model.showHiddenFiles = show
            model.reload()
        }
        .alert(
            "Не удалось выполнить операцию",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("ОК", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
