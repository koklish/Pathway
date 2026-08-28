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
                update: updates,
                onNewConnection: {
                    connectModel.startNewConnection()
                    showConnectServer = true
                },
                onEditServer: { server in
                    connectModel.startEditing(server)
                    showConnectServer = true
                },
                onAuthenticateServer: { server, reason in
                    connectModel.startAuthenticating(server, reason: reason)
                    showConnectServer = true
                }
            )
            .onboardingTarget(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            VStack(spacing: 0) {
                TabBarView(tabs: appState.tabs)
                Divider()
                AddressBarView(model: model, search: appState.search)
                    .onboardingTarget(.addressBar)
                Divider()
                if appState.search.isActive {
                    SearchResultsView(search: appState.search, model: model)
                } else {
                    FileListView(
                        model: model, actions: actions, appState: appState,
                        renamingItem: $state.pendingRename
                    ) { items in
                        appState.pendingCompress = items
                    }
                    // Своя таблица на вкладку. Без этого NSScrollView был бы
                    // один на всех, и переключение вкладок роняло бы позицию
                    // скролла в ту, что осталась от прошлой папки: скролл
                    // принадлежит вью, а не модели, и переприсваиванием model
                    // не восстанавливается.
                    .id(appState.tabs.active.id)
                }
                Divider()
                StatusBarView(model: model)
            }
            // Клик по пустому месту — отступам, статус-бару, фону — снимает фокус
            // с адресной строки. Без этого поле ввода отпускает фокус только на
            // Enter, Esc или переходе в другую папку.
            //
            // При открытой выдаче поиска ловец выключен: SwiftUI List рисует
            // выделение, только владея фокусом, и сброс в том же цикле событий
            // гасил бы подсветку мгновенно — клик выглядел бы как попадание в
            // мёртвую область. NSTableView в списке файлов от этого не страдает:
            // он держит выделение независимо от фокуса.
            .background {
                if !appState.search.isActive {
                    ClickCatcher { NSApp.keyWindow?.makeFirstResponder(nil) }
                }
            }
            // Переход в другую папку закрывает поиск: выдача относится к папке,
            // в которой искали, и оставлять её поверх новой — значит показывать
            // пути, ведущие не туда, куда пришли.
            .onChange(of: model.pane.path) { _, _ in
                if appState.search.isActive { appState.search.cancel() }
            }
        }
        // Обучающий тур поверх всего окна. Якоря целей собраны из дочерних вью
        // (.onboardingTarget), здесь переводятся в координаты overlay и уходят в
        // OnboardingOverlay. Слой рисуется, только пока тур идёт.
        .overlayPreferenceValue(OnboardingAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if appState.onboarding.isActive {
                    OnboardingOverlay(
                        onboarding: appState.onboarding,
                        targets: anchors.mapValues { proxy[$0] },
                        bounds: proxy.size
                    )
                }
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.2), value: appState.onboarding.currentStep)
        }
        .toolbar {
            // Кнопка серверов, «?» и значок версии — одна группа в правом углу:
            // все с .sharedBackgroundVisibility(.hidden), чтобы капсулу рисовал
            // каждый сам, без стеклянной подложки тулбара macOS 26 (иначе они
            // смотрелись бы разнородно — часть кружком-стеклом, часть плоской
            // капсулой). Порядок объявления = порядок слева направо в секции
            // primaryAction: серверы, «?», версия. Под #available: target —
            // macOS 15, где этого API нет.
            if #available(macOS 26, *) {
                ToolbarItem(placement: .primaryAction) {
                    serverMenuButton
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) {
                    HelpBadgeView { appState.onboarding.start() }
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) {
                    UpdateBadgeView(service: updates)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    serverMenuButton
                }
                ToolbarItem(placement: .primaryAction) {
                    HelpBadgeView { appState.onboarding.start() }
                }
                ToolbarItem(placement: .primaryAction) {
                    UpdateBadgeView(service: updates)
                }
            }
        }
        .onAppear {
            // Читает папку активной вкладки. Остальные — восстановленные из
            // прошлой сессии — ждут своего показа: обходить каталоги всех
            // сразу значило бы на сетевом диске десять обходов на старте.
            appState.tabs.loadActive()
            // Подключённый том открываем новой вкладкой, а не вместо текущей:
            // папка, из которой пошли подключаться, должна остаться на месте.
            connectModel.onMounted = { mountPoint in
                showConnectServer = false
                appState.tabs.open(mountPoint, activate: true)
            }
            connectModel.onSettingsSaved = { showConnectServer = false }
            // Том могли отключить мимо нас, пока окно было закрыто.
            connection.mounted.refresh()
        }
        // Тома подключают и отключают в Finder, не выходя из Pathway, —
        // при возврате в приложение список нужно перечитать.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            connection.mounted.refresh()
            // Пока приложение было в фоне, слежение не велось: возвращаем его и
            // разом подбираем всё, что изменилось за это время.
            appState.browser.resumeWatching()
            appState.browser.refreshAfterReturn()
        }
        // Сон рвёт соединение с сервером, но том остаётся в таблице
        // монтирования: система считает его существующим, а обращение к нему
        // виснет. Снимаем такие тома и монтируем заново.
        //
        // Из notificationCenter самого NSWorkspace, а не из NotificationCenter
        // .default: didWakeNotification приходит только туда, и подписка на
        // дефолтный центр молча не сработала бы никогда.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task {
                await connection.reconnectStaleVolumes()
                // После восстановления соединения: открытая на сетевом томе
                // вкладка обязана перечитать папку, иначе покажет список,
                // прочитанный до сна.
                appState.browser.refreshAfterReturn()
            }
        }
        // Список, которого не видно, обновлять незачем, а слежение за сетевой
        // папкой продолжало бы держать соединение с сервером.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appState.browser.stopWatching()
        }
        // Пока открыт диалог с полями ввода, файловые команды гасятся. Сброс
        // висит на onDisappear, а не на кнопках: Esc закрывает лист мимо них.
        .sheet(isPresented: $showConnectServer) {
            ConnectServerView(model: connectModel) { showConnectServer = false }
                .modalTextEditing(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.pendingClone != nil }, set: { if !$0 { appState.pendingClone = nil } }
        )) {
            if let destination = appState.pendingClone {
                CloneDialogView(model: model, destination: destination) { appState.pendingClone = nil }
                    .modalTextEditing(appState)
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.pendingBranchSwitch != nil },
            set: { if !$0 { appState.pendingBranchSwitch = nil } }
        )) {
            if let repository = appState.pendingBranchSwitch {
                BranchSwitchSheet(model: model, repository: repository) {
                    appState.pendingBranchSwitch = nil
                }
                .modalTextEditing(appState)
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.pendingCompress != nil }, set: { if !$0 { appState.pendingCompress = nil } }
        )) {
            if let items = appState.pendingCompress {
                CompressDialogView(model: model, items: items) { appState.pendingCompress = nil }
                    .modalTextEditing(appState)
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.pendingBatchRename != nil }, set: { if !$0 { appState.pendingBatchRename = nil } }
        )) {
            if let items = appState.pendingBatchRename {
                BatchRenameSheet(model: model, items: items) { appState.pendingBatchRename = nil }
                    .modalTextEditing(appState)
            }
        }
        // Свойства: только чтение, поэтому без .modalTextEditing — редактируемых
        // полей нет, поднимать isEditingText незачем.
        .sheet(isPresented: Binding(
            get: { appState.pendingProperties != nil }, set: { if !$0 { appState.pendingProperties = nil } }
        )) {
            if let subject = appState.pendingProperties {
                PropertiesDialogView(subject: subject) { appState.pendingProperties = nil }
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
        // Сетевой том без Корзины: удаление сразу и навсегда, с подтверждением.
        .alert("Удалить безвозвратно?", isPresented: Binding(
            get: { model.pendingPermanentDelete != nil },
            set: { if !$0 { model.cancelPermanentDelete() } }
        )) {
            Button("Удалить", role: .destructive) { model.deletePermanently() }
            Button("Отмена", role: .cancel) { model.cancelPermanentDelete() }
        } message: {
            let count = model.pendingPermanentDelete?.count ?? 0
            Text("На сетевом томе нет Корзины: выделенные объекты (\(count) шт.) будут удалены сразу и навсегда, восстановить их будет нельзя.")
        }
        // Отдельного onChange для скрытых файлов больше нет: флаг живёт в
        // TabsModel и сам раздаётся всем вкладкам с перечитыванием — иначе
        // ⌘⇧. обновлял бы только ту вкладку, что сейчас на экране.
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

    // MARK: - Кнопка серверов

    /// Кнопка «Серверы» для тулбара. Держит те же connection/connectModel, что и
    /// сайдбар, — состояние подключений у них общее.
    private var serverMenuButton: some View {
        ServerMenuButton(
            connection: connection,
            onNewConnection: {
                connectModel.startNewConnection()
                showConnectServer = true
            },
            onOpen: openServer
        )
    }

    /// Переход к серверу из меню: смонтированный открываем сразу, иначе сначала
    /// подключаем и переходим по успеху. Повторяет логику ServerRow в сайдбаре.
    private func openServer(_ server: ServerAddress) {
        if let point = connection.mounted.mountPoint(for: server) {
            appState.tabs.open(point, activate: true)
            return
        }
        Task {
            switch await connection.connect(to: server) {
            case .mounted(let point):
                appState.tabs.open(point, activate: true)
            case .needsCredentials(_, let reason):
                // Форма входа, а не настройки: её кнопка подключается, а
                // «Сохранить» в настройках только записала бы пароль и закрыла
                // окно, оставив сервер отключённым.
                connectModel.startAuthenticating(server, reason: reason)
                showConnectServer = true
            case .failed(let message):
                model.errorMessage = message
            }
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
