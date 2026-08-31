import AppKit
import PathwayCore
import SwiftUI

/// Панель коммитов: незакоммиченные изменения сверху, история с графом снизу.
///
/// Правая панель окна, а не отдельное окно: файлы и коммиты — одна работа, и
/// уводить историю в другое окно значило бы переключаться между ними каждый раз.
struct CommitsPanel: View {
    let model: CommitsModel
    let browser: BrowserModel
    /// Репозиторий, историю которого показывать; nil — репозиторий текущей
    /// папки. Отличается от текущего, когда панель открыли правым кликом по
    /// папке проекта из списка.
    let repository: URL?
    /// Закрытие приходит снаружи: панель не знает, чем её показали.
    let onClose: () -> Void

    /// Корень, с которым панель работает.
    private var root: URL? { repository ?? browser.currentRepository?.root }

    @Environment(AppState.self) private var appState
    /// Высота секции изменений. Живёт здесь, а не в модели: это раскладка, а
    /// Core размеров не считает.
    @State private var changesHeight: CGFloat = 220
    @State private var selectedChange: String?
    /// Курсор в поле сообщения: по нему гасятся файловые команды.
    @FocusState private var messageFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let commit = model.selectedCommit {
                CommitDetailView(commit: commit, files: model.selectedFiles) {
                    model.deselect()
                }
            } else {
                changesSection
                    .frame(height: changesHeight)
                ResizeHandle(height: $changesHeight)
            }

            historySection
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: root) { await load() }
        // Правки снаружи — сохранение в редакторе, коммит из терминала —
        // приходят тем же наблюдателем, что обновляет список файлов: без этого
        // панель показывала бы состояние на момент открытия.
        //
        // По счётчику событий, а не по числу файлов: сохранение существующего
        // файла состава списка не меняет, и по items.count самая частая правка
        // прошла бы мимо панели.
        .onChange(of: browser.externalChangeCount) { _, _ in
            Task { await model.refresh() }
        }
        .alert(
            "Не удалось выполнить операцию git",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("ОК", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// Имя ветки показанного репозитория.
    ///
    /// У текущего оно уже посчитано в currentRepository; у кликнутого читается
    /// из HEAD — это чтение мелкого файла, а не запуск git.
    private var branchName: String? {
        guard let root else { return nil }
        if root == browser.currentRepository?.root { return browser.currentRepository?.branch }
        return GitRepository.branch(at: root)
    }

    private func load() async {
        guard let root else { return }
        await model.load(repository: root)
    }

    // MARK: - Заголовок

    private var header: some View {
        HStack(spacing: 8) {
            Text("Коммиты")
                .font(.system(size: 12.5, weight: .semibold))

            if let branch = branchName {
                Text(branch)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 18, height: 18)
            } else {
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Обновить")
            }

            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Закрыть панель (⌥⌘G)")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: - Изменения

    private var changesSection: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Изменения", count: "\(model.changes.count)") {
                if !model.changes.isEmpty {
                    Button(model.checkedCount == model.changes.count ? "Снять всё" : "Выбрать всё") {
                        Task { await model.setAllChecked(model.checkedCount != model.changes.count) }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .disabled(model.isBusy)
                }
            }

            if model.changes.isEmpty {
                EmptyNote("Нет изменений")
            } else {
                List(selection: $selectedChange) {
                    ForEach(model.changes) { change in
                        ChangeRow(change: change, isBusy: model.isBusy) { checked in
                            Task { await model.setChecked(checked, for: change.path) }
                        }
                        .tag(change.path)
                        .contextMenu { changeMenu(change) }
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 22)
            }

            // Поле сообщения скрыто, когда коммитить нечего: пустое поле над
            // словами «Нет изменений» предлагало бы действие, которого нет.
            if !model.changes.isEmpty {
                commitBox
            }
        }
    }

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 7) {
            @Bindable var model = model
            TextEditor(text: $model.message)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(height: 52)
                .focused($messageFocused)
                // Пока курсор в поле, файловые команды гасятся: F2, ⌘⌫ и ⌘⇧N
                // текстовое поле не перехватывает само, и ⌘⌫ посреди набора
                // сообщения отправил бы выделенные файлы в Корзину.
                //
                // По фокусу, а не по появлению панели: панель немодальная и
                // живёт открытой, пока с файлами работают, — подними флаг на
                // всё это время, и F2 не работал бы вовсе.
                .onChange(of: messageFocused) { _, focused in
                    appState.isEditingText = focused
                }
                // Панель закрывают и с фокусом в поле: без сброса флаг остался
                // бы поднятым и файловые команды не вернулись бы до следующего
                // клика в поле ввода.
                .onDisappear { appState.isEditingText = false }
                // ⌘⏎ ловится здесь, а не .keyboardShortcut на кнопке: у кнопки
                // шорткат гаснет вместе с её .disabled — а кнопка погашена
                // ровно до тех пор, пока сообщение пустое, то есть до первого
                // набранного символа клавиша была бы мертва. Тем же приёмом
                // живёт Esc в поле поиска.
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    guard model.canCommit else { return .handled }
                    Task { await model.commit() }
                    return .handled
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                )
                .overlay(alignment: .topLeading) {
                    // Своя подсказка: у TextEditor нет placeholder, а пустое
                    // поле не говорит, что от человека ждут.
                    if model.message.isEmpty {
                        Text("Сообщение коммита")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 7) {
                Button("Закоммитить \(model.checkedCount)") {
                    Task { await model.commit() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!model.canCommit)
                .help(commitObstacle ?? "Создать коммит (⌘⏎)")

                Button("и Push") {
                    Task {
                        // Push только после удачного коммита: отправлять после
                        // отказа значило бы слать прежнее состояние, о котором
                        // человек уже не думает.
                        if await model.commit() {
                            browser.gitPush(at: model.repository)
                        }
                    }
                }
                .controlSize(.small)
                .disabled(!model.canCommit)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    /// Что мешает коммиту; nil — ничто.
    private var commitObstacle: String? {
        if model.checkedCount == 0 { return "Отметьте хотя бы один файл" }
        if model.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Напишите сообщение коммита"
        }
        return nil
    }

    @ViewBuilder
    private func changeMenu(_ change: GitChange) -> some View {
        Button("Показать в Проводнике") { reveal(change) }
        Button("Показать в Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL(change)])
        }
        Divider()
        Button("Откатить изменения…", role: .destructive) {
            Task { await model.discard([change.path]) }
        }
        .disabled(model.isBusy)
    }

    /// Переводит основной список в папку файла и выделяет его.
    ///
    /// Тем же методом, что и переход из поиска: выделение там отложено до
    /// прихода списка — папка читается асинхронно, и выставленное сразу
    /// указывало бы на файл, которого в items ещё нет.
    private func reveal(_ change: GitChange) {
        let url = fileURL(change)
        browser.navigate(to: url.deletingLastPathComponent(), revealing: url)
    }

    private func fileURL(_ change: GitChange) -> URL {
        (model.repository ?? root ?? browser.pane.path).appendingPathComponent(change.path)
    }

    // MARK: - История

    private var historySection: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "История", count: model.commits.isEmpty ? "" : "\(model.commits.count)") {
                EmptyView()
            }

            if model.commits.isEmpty {
                EmptyNote("Ещё нет коммитов")
                Spacer(minLength: 0)
            } else {
                List {
                    ForEach(Array(model.commits.enumerated()), id: \.element.id) { index, commit in
                        CommitRow(
                            commit: commit,
                            row: index < model.rows.count ? model.rows[index] : nil,
                            isFirst: index == 0
                        )
                        // Нулевые отступы строки: свои вертикальные List
                        // вставил бы между строками, и колонка графа не
                        // доставала бы до соседней — вертикаль рвалась бы на
                        // каждой границе.
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .padding(.trailing, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await model.select(commit) } }
                        .onAppear {
                            // Догрузка по подходу к концу: читать всю историю
                            // сразу — секунды ожидания на большом репозитории.
                            if commit.id == model.commits.last?.id {
                                Task { await model.loadMore() }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 24)
            }
        }
    }
}

// MARK: - Строка изменения

private struct ChangeRow: View {
    let change: GitChange
    let isBusy: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 7) {
            // Замыкание обёрнуто, а не передано в set: напрямую: переданное
            // прямо, оно теряет изоляцию главного актора и компилятор
            // предупреждает о гонке.
            Toggle("", isOn: Binding(
                get: { change.isStaged },
                set: { checked in onToggle(checked) }
            ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.mini)
                // Конфликт в индекс не добавить, пока он не разрешён: живая
                // галочка на нём обещала бы работающий коммит.
                .disabled(isBusy || change.status == .conflicted)

            Text(change.status.letter)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 12)
                // Буква вместе с цветом: различение по одному оттенку отсекает
                // тех, кто его не видит.
                .help(statusName)

            Text(change.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                // Частично добавленный файл: коммит возьмёт не все правки, и
                // об этом стоит знать до нажатия кнопки.
                .italic(change.isPartiallyStaged)

            Spacer(minLength: 6)

            if !change.directory.isEmpty {
                Text(change.directory)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .help(change.oldPath.map { "Прежнее имя: \($0)" } ?? change.path)
    }

    private var color: Color {
        switch change.status {
        case .modified: .orange
        case .added, .renamed: .green
        case .deleted: .red
        case .conflicted: .red
        case .untracked: .secondary
        }
    }

    private var statusName: String {
        switch change.status {
        case .modified: "Изменён"
        case .added: "Добавлен"
        case .deleted: "Удалён"
        case .renamed: "Переименован"
        case .untracked: "Новый, не отслеживается"
        case .conflicted: "Конфликт — разрешите его в терминале"
        }
    }
}

// MARK: - Строка истории

private struct CommitRow: View {
    let commit: Commit
    let row: GraphRow?
    /// Самая верхняя строка истории: над ней рисовать нечего.
    let isFirst: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Без фиксированной высоты и с растяжением на всю строку: холст
            // ниже строки оставлял бы зазор между соседними, и вертикаль
            // рвалась бы на каждой границе — линия обязана идти от точки к
            // точке сплошной, как в любом git-клиенте.
            GraphLane(
                row: row,
                isHead: commit.refs.contains { $0.kind == .head },
                isFirst: isFirst
            )
                .frame(width: laneWidth)
                .frame(maxHeight: .infinity)

            // Слияния приглушены: в ветвистой истории их до трети, и в полную
            // силу они забивали бы содержательные сообщения.
            Text(commit.subject)
                .font(.system(size: 12))
                .foregroundStyle(commit.isMerge ? .secondary : .primary)
                .lineLimit(1)

            ForEach(commit.refs, id: \.self) { ref in
                RefBadge(ref: ref)
            }

            Spacer(minLength: 4)

            Text(commit.author)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 70, alignment: .trailing)

            Text(Self.formatter.string(from: commit.date))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .help("\(commit.shortHash) · \(commit.author) · \(Self.full.string(from: commit.date))")
    }

    /// Ширина колонки графа: по числу дорожек, но не больше пяти — дальше
    /// граф съедал бы сообщения, ради которых список и открывают.
    private var laneWidth: CGFloat {
        CGFloat(min(row?.width ?? 1, 5)) * 12 + 8
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.setLocalizedDateFormatFromTemplate("ddMMM")
        return formatter
    }()

    private static let full: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Бейдж ветки или тега рядом с сообщением.
private struct RefBadge: View {
    let ref: CommitRef

    var body: some View {
        Text(name)
            .font(.system(size: 9.5, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(color.opacity(0.12))
                    .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
            )
            .foregroundStyle(color)
            .help(ref.name)
    }

    /// Длинные серверные имена урезаются с начала: имя удалённого одинаково у
    /// всех, а номер задачи в хвосте — то, чем ветки различаются.
    private var name: String {
        guard ref.name.count > 18, let slash = ref.name.firstIndex(of: "/") else { return ref.name }
        return "…" + ref.name[ref.name.index(after: slash)...].suffix(16)
    }

    private var color: Color {
        switch ref.kind {
        case .head: .accentColor
        case .branch: .accentColor
        case .remote: .secondary
        case .tag: .orange
        }
    }
}

// MARK: - Общие мелочи

private struct SectionHeader<Trailing: View>: View {
    let title: String
    let count: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .kerning(0.6)
                .foregroundStyle(.secondary)

            if !count.isEmpty {
                Text(count)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct EmptyNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }
}

/// Полоса между секциями: тянется мышью по вертикали.
///
/// Жест меряется в координатах окна по той же причине, что и у ручки ширины
/// панели: полоса лежит под секцией, высоту которой меняет, и в собственной
/// системе отсчёта переезжала бы под курсором — высота колебалась бы между
/// двумя значениями, и это видно как дёрганье.
private struct ResizeHandle: View {
    @Binding var height: CGFloat
    /// Высота и точка курсора на момент начала жеста.
    @State private var start: (height: CGFloat, y: CGFloat)?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            // Полоса захвата шире линии: попасть мышью в один пиксель нельзя.
            .frame(height: 7)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(resizeCoordinateSpace))
                    .onChanged { value in
                        let origin = start ?? (height, value.startLocation.y)
                        start = origin
                        // Границы: секция не должна ни схлопнуться в невидимую
                        // полоску, ни съесть историю целиком.
                        height = ResizeDrag.size(
                            start: origin.height,
                            from: origin.y, to: value.location.y,
                            // Секция лежит над разделителем: тянут вниз — растёт.
                            growth: .direct, limits: 90...460
                        )
                    }
                    .onEnded { _ in start = nil }
            )
    }
}
