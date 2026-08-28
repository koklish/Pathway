import PathwayCore
import SwiftUI

/// Лист «Все ветки»: выбор ветки с поиском.
///
/// Отдельный лист, а не длинное подменю: в рабочем репозитории веток бывает
/// семьдесят, и без поиска такой список бесполезен, а поиск в NSMenu не живёт.
struct BranchSwitchSheet: View {
    let model: BrowserModel
    let repository: URL
    let dismiss: () -> Void

    @State private var branches: [Branch] = []
    @State private var query = ""
    @State private var selected: Branch?
    @State private var isLoading = true
    /// Раскрытые папки по полному пути. Путь, а не имя: хвост «SRM»
    /// встречается под разными префиксами, и по имени раскрывались бы обе.
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchField
            list
            footer
        }
        .frame(width: 460, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            // Читается при открытии, без кэша: 70 веток выдаются за десяток
            // миллисекунд, а хранимый список устарел бы от первой же операции
            // в терминале.
            branches = await model.gitBranches(at: repository)
            isLoading = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Переключить ветку")
                .font(.system(size: 20, weight: .bold))
            Text(repository.lastPathComponent)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Поиск по названию", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color(nsColor: .separatorColor))
                }
        }
        .padding(.horizontal, 28)
    }

    @ViewBuilder
    private var list: some View {
        if isLoading {
            centered { ProgressView().controlSize(.small) }
        } else if filtered.isEmpty {
            // Разный текст для пустого поиска и пустого репозитория: «ничего не
            // найдено» в репозитории без веток вводило бы в заблуждение.
            centered {
                Text(query.isEmpty ? "Веток нет" : "Ничего не найдено")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    group("Локальные", filtered.filter { !$0.isRemote })
                    group("На сервере", filtered.filter(\.isRemote))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [Branch]) -> some View {
        if !items.isEmpty {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 4)

            // Дерево строится на каждый рендер: узлов десятки, сборка стоит
            // микросекунды, а кэш пришлось бы сбрасывать при смене поиска.
            ForEach(BranchTree.build(items)) { node in
                nodeView(node, depth: 0)
            }
        }
    }

    /// Узел дерева: папка с раскрытием или строка ветки.
    ///
    /// AnyView обязателен: метод зовёт сам себя для детей, и вывод opaque-типа
    /// «some View» определял бы тип через самого себя — компилятор такое
    /// отвергает. Стирание типа здесь безвредно: узлов десятки, не тысячи.
    private func nodeView(_ node: BranchNode, depth: Int) -> AnyView {
        if let branch = node.branch {
            return AnyView(row(branch, title: node.title, depth: depth))
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 1) {
                folderRow(node, depth: depth)
                if isExpanded(node) {
                    ForEach(node.children) { child in
                        nodeView(child, depth: depth + 1)
                    }
                }
            }
        )
    }

    private func folderRow(_ node: BranchNode, depth: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: isExpanded(node) ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 11)

            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(node.title)
                .font(.system(size: 12))
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(node.leafCount)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, CGFloat(depth) * 16 + 8)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { toggle(node) }
    }

    /// Папка раскрыта, если её путь в множестве — либо если идёт поиск.
    ///
    /// При поиске раскрыто всё: свёрнутая папка спрятала бы найденное, и
    /// человек решил бы, что совпадений нет.
    private func isExpanded(_ node: BranchNode) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || expanded.contains(node.path)
    }

    private func toggle(_ node: BranchNode) {
        if expanded.contains(node.path) {
            expanded.remove(node.path)
        } else {
            expanded.insert(node.path)
        }
    }

    private func row(_ branch: Branch, title: String, depth: Int) -> some View {
        let isSelected = selected == branch
        return HStack(spacing: 9) {
            Image(systemName: branch.isRemote
                  ? "arrow.down.circle"
                  : "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? .white : .secondary)

            // Хвост имени, а не имя целиком: префикс уже назван папкой выше,
            // и повторять «feature/SRM/» в каждой из 62 строк незачем.
            Text(title)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if branch.isCurrent {
                Text("текущая")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background {
                        Capsule().fill(isSelected
                                       ? Color.white.opacity(0.2)
                                       : Color.accentColor.opacity(0.15))
                    }
            } else if let date = branch.date {
                Text(date.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
        }
        .foregroundStyle(isSelected ? .white : .primary)
        .padding(.leading, CGFloat(depth) * 16 + 8)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : .clear)
        }
        .contentShape(Rectangle())
        // Текущая не выбирается: git переключение на себя пропустит, но
        // кнопка, которая ничего не делает, выглядит сломанной.
        .onTapGesture { if !branch.isCurrent { selected = branch } }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()

            Button("Отмена", action: dismiss)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .keyboardShortcut(.cancelAction)

            Button(action: submit) {
                // Надпись меняется по цели: заведение локальной копии — не то
                // же, что переход, и кнопка обязана сказать, что произойдёт.
                Text(selected?.isRemote == true ? "Создать и переключить" : "Переключить")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selected == nil
                                  ? Color.accentColor.opacity(0.5)
                                  : Color.accentColor)
                    }
            }
            .buttonStyle(.plain)
            .disabled(selected == nil)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    /// Отбор по подстроке без учёта регистра: имена веток в разных проектах
    /// пишут и строчными, и с заглавных, а человек ищет как помнит.
    private var filtered: [Branch] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return branches }
        return branches.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }

    private func submit() {
        guard let selected else { return }
        model.gitSwitch(to: selected, at: repository)
        dismiss()
    }
}
