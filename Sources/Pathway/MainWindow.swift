import PathwayCore
import SwiftUI

/// Главное окно: сайдбар + адресная строка + список файлов + статус-бар.
struct MainWindow: View {
    @Environment(AppState.self) private var appState
    @State private var model = BrowserModel(path: FileManager.default.homeDirectoryForCurrentUser)
    @State private var renamingItem: URL?
    /// Элементы, для которых открыт диалог архивации; nil — диалог закрыт.
    @State private var compressItems: [FileItem]?
    @State private var showConnectServer = false
    @State private var connection = ServerConnection()
    @State private var connectModel: ConnectServerModel
    /// Избранное берётся из общего AppState, чтобы сайдбар и список файлов
    /// меняли один и тот же список.
    private var actions: FolderActions { appState.folderActions }

    init() {
        // Диалог и сайдбар должны видеть одно состояние подключений.
        let connection = ServerConnection()
        _connection = State(initialValue: connection)
        _connectModel = State(initialValue: ConnectServerModel(connection: connection))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                model: model,
                connection: connection,
                actions: actions,
                onNewConnection: {
                    connectModel.startNewConnection()
                    showConnectServer = true
                },
                onEditServer: { server in
                    connectModel.startEditing(server)
                    showConnectServer = true
                }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            VStack(spacing: 0) {
                AddressBarView(model: model)
                Divider()
                FileListView(model: model, actions: actions, renamingItem: $renamingItem) { items in
                    compressItems = items
                }
                Divider()
                StatusBarView(model: model)
            }
            // Клик по пустому месту — отступам, статус-бару, фону — снимает фокус
            // с адресной строки. Без этого поле ввода отпускает фокус только на
            // Enter, Esc или переходе в другую папку.
            .background {
                ClickCatcher { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
        }
        .onAppear {
            model.showHiddenFiles = appState.showHiddenFiles
            model.reloadAsync()
            // Подключённый том сразу открываем в панели и закрываем диалог.
            connectModel.onMounted = { mountPoint in
                showConnectServer = false
                model.navigate(to: mountPoint)
            }
            connectModel.onSettingsSaved = { showConnectServer = false }
            // Том могли отключить мимо нас, пока окно было закрыто.
            connection.mounted.refresh()
        }
        // Тома подключают и отключают в Finder, не выходя из Pathway, —
        // при возврате в приложение список нужно перечитать.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            connection.mounted.refresh()
        }
        .sheet(isPresented: $showConnectServer) {
            ConnectServerView(model: connectModel) { showConnectServer = false }
        }
        .sheet(isPresented: Binding(
            get: { compressItems != nil }, set: { if !$0 { compressItems = nil } }
        )) {
            if let items = compressItems {
                CompressDialogView(model: model, items: items) { compressItems = nil }
            }
        }
        // Распаковка наткнулась на зашифрованный архив — спрашиваем пароль.
        .sheet(isPresented: Binding(
            get: { model.passwordRequest != nil }, set: { if !$0 { model.cancelPasswordRequest() } }
        )) {
            if let request = model.passwordRequest {
                ExtractPasswordView(model: model, request: request)
            }
        }
        .onChange(of: appState.showHiddenFiles) { _, show in
            model.showHiddenFiles = show
            model.reloadAsync()
        }
        .alert(
            "Не удалось выполнить операцию",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("ОК", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            "Не удалось открыть терминал",
            isPresented: Binding(get: { actions.errorMessage != nil }, set: { if !$0 { actions.errorMessage = nil } })
        ) {
            Button("ОК", role: .cancel) { actions.errorMessage = nil }
        } message: {
            Text(actions.errorMessage ?? "")
        }
    }
}
