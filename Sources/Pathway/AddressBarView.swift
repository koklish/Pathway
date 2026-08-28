import PathwayCore
import SwiftUI

/// Адресная строка: кнопки навигации и поле пути, которое переключается
/// между хлебными крошками и вводом текста (как в Проводнике Windows).
struct AddressBarView: View {
    let model: BrowserModel
    /// Поиск стоит в этой же строке, а не отдельным вью в MainWindow: там ему
    /// пришлось бы повторять вертикальные отступы строки, и поля разъезжались
    /// бы по высоте при любой правке одного из них.
    let search: SearchModel
    @Environment(AppState.self) private var appState

    @State private var isEditing = false
    @State private var pathText = ""
    @FocusState private var fieldFocused: Bool
    /// Локальные ветки текущего репозитория для меню чипа.
    ///
    /// Читаются заранее, а не при открытии меню: SwiftUI строит содержимое
    /// Menu до показа, и асинхронная загрузка успела бы только к следующему
    /// открытию — первый клик показал бы пустое место.
    @State private var recentBranches: [Branch] = []

    var body: some View {
        HStack(spacing: 8) {
            navigationButtons
            pathControl
            branchIndicator
            SearchFieldView(search: search, directory: model.pane.path)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: model.pane.path) { _, _ in isEditing = false }
        // Перечитываем на смену репозитория и после операций: переключение
        // ветки меняет, какая из них текущая, а fetch может принести новые.
        .task(id: model.currentRepository) { await loadBranches() }
        // Пока строка в режиме ввода, файловые команды гасятся: ⌘C должна
        // копировать текст пути, а F2 и ⌘⌫ — не трогать выделенные файлы.
        .onChange(of: isEditing) { _, editing in appState.isEditingText = editing }
        .onDisappear { appState.isEditingText = false }
        // ⌘L из главного меню: команда не может сама сфокусировать поле,
        // поэтому выставляет запрос, а строка его исполняет.
        .onChange(of: appState.pendingEditPath) { _, pending in
            guard pending else { return }
            beginEditing()
            appState.pendingEditPath = false
        }
    }

    /// Ветка репозитория, внутри которого находится текущая папка.
    ///
    /// Рядом с путём, а не в статус-баре: путь и ветка — одна мысль, «где я
    /// нахожусь», и разнесённые по разным краям окна они заставляли бы глаз
    /// метаться.
    ///
    /// Здесь чип ещё и кнопка — в отличие от списка, где левый клик занят
    /// выделением строки. Шеврон рисуется только тут и служит признаком того,
    /// что по чипу можно нажать.
    @ViewBuilder
    private var branchIndicator: some View {
        if let repository = model.currentRepository, let branch = repository.branch {
            Menu {
                branchMenuItems(repository, branch: branch)
            } label: {
                BranchChipLabel(repository: repository, branch: branch)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Ветка: \(branch)" + (repository.isDirty ? " · есть незакоммиченные изменения" : ""))
        } else {
            // Место под индикатор занято всегда: появляющийся и исчезающий
            // элемент дёргал бы раскладку строки при каждом переходе из
            // проекта в обычную папку.
            Color.clear.frame(width: 1, height: 20)
        }
    }

    /// Пункты меню операций.
    ///
    /// Английские названия — по решению владельца проекта: Pull, Push и Fetch
    /// суть имена операций в самом git, и перевод заставлял бы сверять
    /// «Загрузить» с git pull при каждом чтении.
    @ViewBuilder
    private func branchMenuItems(_ repository: RepositoryState, branch: String) -> some View {
        // Заголовком — имя ветки: меню открывается и от чипа в списке, где
        // кликнутая строка и выделенная суть разные вещи, и без подписи Push
        // уходил бы в проект, о котором человек не думал.
        Section(branch) {
            // Причина в help, а не второй строкой пункта: SwiftUI Menu
            // двухстрочных пунктов не умеет вовсе.
            gitItem(.gitPull, blockedBy: pullObstacle(repository))

            gitItem(.gitPush, title: pushTitle(repository),
                    blockedBy: repository.ahead == nil ? "No upstream branch" : nil)

            // Sync начинается с pull, поэтому наследует и его препятствие:
            // при грязном дереве он свалится на первом же шаге, и активный
            // пункт рядом с погашенным Pull обещал бы несуществующее.
            gitItem(.gitSync, title: syncTitle(repository),
                    blockedBy: pullObstacle(repository)
                        ?? (repository.ahead == nil ? "No upstream branch" : nil))

            gitItem(.gitFetch)
        }

        Divider()

        branchItems(repository)

        Divider()

        gitItem(.gitCopyBranch)
    }

    /// Недавние ветки и вход в полный список.
    ///
    /// Пять, а не все: в рабочем репозитории их семьдесят, и вывались бы они
    /// целиком — меню ушло бы за край экрана. Только локальные: серверная
    /// требует создания ветки, и в коротком списке без пояснения это выглядело
    /// бы обычным переходом.
    @ViewBuilder
    private func branchItems(_ repository: RepositoryState) -> some View {
        ForEach(recentBranches.prefix(5)) { branch in
            Button {
                model.gitSwitch(to: branch, at: repository.root)
            } label: {
                // Галочка текстом, а не Toggle: пункт должен остаться кнопкой,
                // а Toggle в Menu рисуется переключателем и обещает состояние,
                // которого у ветки нет.
                Text(branch.isCurrent ? "✓ \(branch.name)" : branch.name)
            }
            // На текущей ветке пункт мёртв: git переключение на себя пропустит
            // молча, но живой пункт, который ничего не делает, выглядит
            // сломанным.
            .disabled(branch.isCurrent || model.isBusy)
        }

        Button("Все ветки…") { appState.pendingBranchSwitch = repository.root }
            .disabled(model.isBusy)
    }

    private func loadBranches() async {
        guard let root = model.currentRepository?.root else {
            recentBranches = []
            return
        }
        recentBranches = await model.gitBranches(at: root).filter { !$0.isRemote }
    }

    /// Что мешает забрать изменения; nil — ничто.
    private func pullObstacle(_ repository: RepositoryState) -> String? {
        repository.isDirty ? "Commit or stash changes first" : nil
    }

    /// Пункт меню: доступность берётся из реестра, а причина — из состояния
    /// репозитория, которое реестру неизвестно.
    /// Заголовок берётся из реестра; параметр нужен лишь там, где к названию
    /// добавляется счётчик коммитов.
    private func gitItem(_ id: CommandID, title: String? = nil, blockedBy reason: String? = nil) -> some View {
        let command = CommandRegistry[id]
        // Причина read-only подставляется здесь, а не в каждом вызове: реестр
        // гасит такие команды сам, и без подписи пункт выглядел бы серым без
        // объяснения — ровно то, что этот приём и должен был устранить.
        let obstacle = reason
            ?? (model.isReadOnlyVolume && CommandRegistry.writesToDisk.contains(id)
                ? "Volume is read-only" : nil)
        return Button(title ?? command.title) { command.run(appState) }
            .disabled(!command.isEnabled(appState) || obstacle != nil)
            .help(obstacle ?? "")
    }

    /// Число коммитов прямо в названии: шортката у git-команд нет и не будет,
    /// место справа пустует, и счётчик там полезнее пустоты.
    private func pushTitle(_ repository: RepositoryState) -> String {
        guard let ahead = repository.ahead, ahead > 0 else { return "Push" }
        return "Push (\(ahead))"
    }

    private func syncTitle(_ repository: RepositoryState) -> String {
        let ahead = repository.ahead ?? 0
        let behind = repository.behind ?? 0
        guard ahead > 0 || behind > 0 else { return "Sync" }
        return "Sync (↓\(behind) ↑\(ahead))"
    }

    /// Шорткаты у кнопок не висят: привязанный к кнопке шорткат гаснет вместе
    /// с её .disabled и не работает, когда фокус в списке файлов. Клавиши
    /// приходят из главного меню, кнопки остаются мышиным дублем.
    private var navigationButtons: some View {
        HStack(spacing: 2) {
            Button { model.goBack() } label: { NavIcon("chevron.left") }
                .disabled(!model.pane.canGoBack)
                .help("Назад (⌘[)")

            Button { model.goForward() } label: { NavIcon("chevron.right") }
                .disabled(!model.pane.canGoForward)
                .help("Вперёд (⌘])")

            Button { model.goUp() } label: { NavIcon("chevron.up") }
                .help("Вверх (⌘↑)")

            Button { model.reloadAsync() } label: { NavIcon("arrow.clockwise") }
                .help("Обновить (⌘R)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
    }

    /// Поле пути: рамка одна и та же в обоих режимах, меняется только начинка.
    private var pathControl: some View {
        HStack(spacing: 6) {
            if isEditing {
                pathField
            } else {
                breadcrumbs
                editButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(height: 30)
        .background(fieldBackground)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isEditing ? Color.accentColor : Color.primary.opacity(0.12),
                        lineWidth: isEditing ? 2 : 1
                    )
            }
    }

    private var pathField: some View {
        TextField("Путь", text: $pathText)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .focused($fieldFocused)
            .onSubmit(commitEditing)
            .onExitCommand { isEditing = false }
            // Клик мимо поля — куда угодно: в список, в сайдбар, в пустое место —
            // должен закрывать ввод. Правку при этом отбрасываем: пользователь
            // ушёл, не подтвердив её, а неявная навигация была бы неожиданной.
            .onChange(of: fieldFocused) { _, focused in
                if !focused { isEditing = false }
            }
            .onAppear {
                fieldFocused = true
                // SwiftUI ставит курсор в конец; макет требует выделения всего пути.
                DispatchQueue.main.async {
                    NSApp.keyWindow?.firstResponder.flatMap { $0 as? NSText }?.selectAll(nil)
                }
            }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 2) {
            ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.url) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 2)
                }
                CrumbButton(
                    crumb: crumb,
                    isLast: index == model.breadcrumbs.count - 1,
                    isRoot: index == 0
                ) {
                    model.navigate(to: crumb.url)
                }
            }

            // Пустое место справа от крошек — тоже вход в режим ввода, как в Проводнике.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { beginEditing() }
        }
    }

    private var editButton: some View {
        Button(action: beginEditing) {
            Image(systemName: "pencil")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Редактировать путь (⌘L)")
    }

    private func beginEditing() {
        // Для сетевой шары показываем UNC: именно этот путь открывается у коллег
        // в Windows, а локальный /Volumes/… осмыслен только на этой машине.
        pathText = NetworkPath.display(for: model.pane.path)
        isEditing = true
    }

    private func commitEditing() {
        let trimmed = pathText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { isEditing = false; return }
        guard let target = PathInput.resolve(trimmed) else {
            // Сетевой адрес введён, но том не подключён — молча ничего не делать
            // хуже, чем сказать, в чём дело.
            model.errorMessage = "Сетевая папка «\(trimmed)» не подключена. Подключите сервер в секции «Сеть», затем повторите."
            isEditing = false
            return
        }
        model.navigate(to: target)
        isEditing = false
    }
}

/// Иконка кнопки навигации в невидимом квадрате 24×24: попадать по тонкому глифу
/// шеврона мышью неудобно, зона клика должна быть заметно больше рисунка.
private struct NavIcon: View {
    let name: String

    init(_ name: String) { self.name = name }

    var body: some View {
        Image(systemName: name)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }
}

/// Один сегмент пути. Подсвечивается под курсором, чтобы кликабельность была очевидна.
private struct CrumbButton: View {
    let crumb: Breadcrumb
    let isLast: Bool
    let isRoot: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isRoot {
                    Image(systemName: "house")
                        .font(.system(size: 11))
                }
                Text(crumb.name)
                    .font(.system(size: 13, weight: isLast ? .medium : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isLast ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering ? Color.primary.opacity(0.07) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(crumb.url.path)
    }
}
