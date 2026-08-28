import Foundation

/// Узел дерева веток: папка префикса или сама ветка.
///
/// Один тип на оба случая, а не два: список рисует их вперемешку в одном
/// цикле, и разделение заставило бы вью различать их на каждом шаге.
public struct BranchNode: Equatable, Sendable, Identifiable {
    /// Полный путь узла: `feature`, `feature/SRM`, `feature/SRM/141`.
    /// Он же идентификатор — два узла с одним путём невозможны.
    public var id: String { path }
    public let path: String
    /// Последний сегмент: то, что видно в строке. Для `feature/SRM/141` — `141`.
    public let title: String
    /// Ветка, если узел — лист; nil — папка префикса.
    public let branch: Branch?
    public let children: [BranchNode]

    public var isFolder: Bool { branch == nil }

    /// Сколько веток лежит под узлом, считая вложенные папки.
    ///
    /// Показывается рядом с папкой: свёрнутая «feature/SRM» без числа не
    /// говорит, стоит ли её раскрывать — там может быть одна ветка, а может
    /// шестьдесят две.
    public var leafCount: Int {
        branch != nil ? 1 : children.reduce(0) { $0 + $1.leafCount }
    }

    public init(path: String, title: String, branch: Branch? = nil, children: [BranchNode] = []) {
        self.path = path
        self.title = title
        self.branch = branch
        self.children = children
    }
}

/// Сборка плоского списка веток в дерево по сегментам имени.
///
/// `feature/SRM/141` становится папкой `feature` → папкой `SRM` → листом
/// `141`. Без этого список выглядит стеной одинаковых строк: в рабочем
/// репозитории 63 ветки из 70 начинаются с `feature/SRM/`, и различаются они
/// только хвостом, до которого глазу приходится дочитывать каждую строку.
public enum BranchTree {

    public static func build(_ branches: [Branch]) -> [BranchNode] {
        // Порядок входа — порядок по свежести, и он должен сохраниться: папка
        // встаёт туда, где встретилась её первая ветка, то есть самая свежая.
        var order: [String] = []
        var groups: [String: [Branch]] = [:]
        var leaves: [String: Branch] = [:]

        for branch in branches {
            let head = branch.name.firstSegment
            if head == branch.name {
                // Ветка без слэша — лист прямо здесь.
                if leaves[head] == nil, groups[head] == nil { order.append(head) }
                leaves[head] = branch
            } else {
                if groups[head] == nil, leaves[head] == nil { order.append(head) }
                groups[head, default: []].append(branch)
            }
        }

        return order.map { head in
            // Ветка и папка с одним именем: git позволяет только одно из двух —
            // «feature» и «feature/x» вместе не существуют. Но если такое
            // всё же встретилось, лист важнее: на него можно переключиться.
            if let branch = leaves[head] {
                return BranchNode(path: head, title: head, branch: branch)
            }
            let nested = groups[head] ?? []
            return node(path: head, title: head, branches: nested)
        }
    }

    /// Собирает узел из веток, у которых уже отрезан общий префикс `path`.
    private static func node(path: String, title: String, branches: [Branch]) -> BranchNode {
        var order: [String] = []
        var groups: [String: [Branch]] = [:]
        var leaves: [String: Branch] = [:]

        for branch in branches {
            // Хвост после уже разобранного префикса.
            let rest = String(branch.name.dropFirst(path.count + 1))
            let head = rest.firstSegment
            if head == rest {
                if leaves[head] == nil, groups[head] == nil { order.append(head) }
                leaves[head] = branch
            } else {
                if groups[head] == nil, leaves[head] == nil { order.append(head) }
                groups[head, default: []].append(branch)
            }
        }

        let children: [BranchNode] = order.map { head in
            let childPath = "\(path)/\(head)"
            if let branch = leaves[head] {
                return BranchNode(path: childPath, title: head, branch: branch)
            }
            return node(path: childPath, title: head, branches: groups[head] ?? [])
        }

        // Папка с единственным ребёнком-папкой схлопывается: «feature» →
        // «SRM» → 63 ветки читается как «feature/SRM» одной строкой, а два
        // раскрытия ради одного пути — лишняя работа руками.
        if children.count == 1, let only = children.first, only.isFolder {
            return BranchNode(path: only.path, title: "\(title)/\(only.title)", children: only.children)
        }
        return BranchNode(path: path, title: title, children: children)
    }
}

private extension String {
    /// Часть имени до первого слэша; всё имя, если слэша нет.
    var firstSegment: String {
        guard let slash = firstIndex(of: "/") else { return self }
        return String(self[startIndex..<slash])
    }
}
