import PathwayCore
import SwiftUI

/// Главное окно: сайдбар + адресная строка + список файлов + статус-бар.
struct MainWindow: View {
    @Environment(AppState.self) private var appState
    @State private var showConnectServer = false
    @State private var connection = ServerConnection()
    @State private var connectModel: ConnectServerModel
    /// Сервис обновлений приходит из App: тот же экземпляр видит пункт меню.
    let updates: UpdateService
    /// Панель живёт в AppState: до неё должны дотягиваться команды главного меню.
    private var model: BrowserModel { appState.browser }
    /// Избранное берётся из общего AppState, чтобы сайдбар и список файлов
    /// меняли один и тот же список.
    private var actions: FolderActions { appState.folderActions }

    init(updates: UpdateService) {
        self.updates = updates
        // Диалог и сайдбар должны видеть одно состояние подключений.
        let connection = ServerConnection()
        _connection = State(initialValue: connection)
        _connectModel = State(initialValue: ConnectServerModel(connection: connection))
    }

    var body: some View {
        @Bindable var state = appState
        return NavigationSplitView {
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
                FileListView(
                    model: model, actions: actions, appState: appState,
                    renamingItem: $state.pendingRename
                ) { items in
                    appState.pendingCompress = items
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
        .toolbar {
            // .automatic отдаёт размещение системе, а она вправе положить
            // элемент в секцию detail вместо правого угла строки заголовка —
            // именно там значок версии должен быть виден всегда. .primaryAction
            // это гарантирует.
            ToolbarItem(placement: .primaryAction) {
                UpdateBadgeView(service: updates)
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
        // Пока открыт диалог с полями ввода, файловые команды гасятся. Сброс
        // висит на onDisappear, а не на кнопках: Esc закрывает лист мимо них.
        .sheet(isPresented: $showConnectServer) {
            ConnectServerView(model: connectModel) { showConnectServer = false }
                .modalTextEditing(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.pendingCompress != nil }, set: { if !$0 { appState.pendingCompress = nil } }
        )) {
            if let items = appState.pendingCompress {
                CompressDialogView(model: model, items: items) { appState.pendingCompress = nil }
                    .modalTextEditing(appState)
            }
        }
        // Распаковка наткнулась на зашифрованный архив — спрашиваем пароль.
        .sheet(isPresented: Binding(
            get: { model.passwordRequest != nil }, set: { if !$0 { model.cancelPasswordRequest() } }
        )) {
            if let request = model.passwordRequest {
                ExtractPasswordView(model: model, request: request)
                    .modalTextEditing(appState)
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

private extension View {
    /// Помечает модальный лист как «идёт ввод текста»: пока он открыт, F2,
    /// ⌘⌫ и другие файловые команды не должны срабатывать под ним.
    func modalTextEditing(_ state: AppState) -> some View {
        onAppear { state.isEditingText = true }
            .onDisappear { state.isEditingText = false }
    }
}
