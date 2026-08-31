import Foundation

/// Отрезок линии в строке графа: сверху с дорожки `from`, снизу к дорожке `to`.
///
/// Одинаковые номера — прямая вертикаль, разные — переход вбок: слияние или
/// схождение ветки обратно в ствол.
public struct GraphLink: Equatable, Sendable, Hashable {
    public let from: Int
    public let to: Int

    public init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }
}

/// Строка графа: точка коммита и линии, проходящие через эту строку.
public struct GraphRow: Equatable, Sendable {
    /// Дорожка, на которой стоит точка коммита.
    public let lane: Int
    /// Индекс цвета дорожки. Закреплён за дорожкой, а не за строкой: иначе
    /// линия меняла бы цвет по дороге и читалась бы как две разные ветки.
    public let color: Int
    /// Сколько дорожек занято в этой строке — по нему вью считает ширину колонки.
    public let width: Int
    public let links: [GraphLink]
    /// В точку коммита приходит линия сверху: его дорожку кто-то уже ждал.
    ///
    /// Отдельный признак, а не ещё один GraphLink: связь означает отрезок через
    /// всю строку, а здесь нужна ровно верхняя половина — от края до точки.
    /// Без него первый коммит ветки висел бы оторванным от слияния, которым
    /// эта ветка началась.
    public let hasLineAbove: Bool

    public init(lane: Int, color: Int, width: Int, links: [GraphLink], hasLineAbove: Bool = false) {
        self.lane = lane
        self.color = color
        self.width = width
        self.links = links
        self.hasLineAbove = hasLineAbove
    }
}

/// Укладка коммитов по дорожкам.
///
/// Чистая функция от списка коммитов: граф проверяется без репозитория, и
/// панель может пересчитать его на любой выборке, не трогая диск.
public enum GitGraph {

    /// Строит строки графа в том же порядке, что и коммиты.
    ///
    /// Алгоритм — «активные дорожки»: сверху вниз держим список хешей, которых
    /// ждём следующими. Коммит встаёт на ту дорожку, где его ждали; его
    /// первый родитель занимает её же, остальные — новые дорожки.
    ///
    /// Именно первый родитель наследует дорожку, а не любой: у слияния первый
    /// родитель — это та ветка, в которую влили, и она обязана идти прямой
    /// линией вниз. Отдай дорожку второму — ствол ветки прыгал бы вбок на
    /// каждом слиянии.
    public static func build(_ commits: [Commit]) -> [GraphRow] {
        // Хеш, которого ждёт дорожка; nil — дорожка свободна и переиспользуема.
        // Дырки не схлопываются: сдвиг номеров сместил бы линии уже нарисованных
        // строк, и вертикаль превратилась бы в лесенку.
        var lanes: [String?] = []
        // Цвет закрепляется за дорожкой при её занятии и живёт, пока она занята.
        var colors: [Int] = []
        var nextColor = 0
        var rows: [GraphRow] = []

        for commit in commits {
            // Ждала ли уже какая-то дорожка этот коммит: если да, к его точке
            // идёт линия сверху. Считается ДО занятия дорожки — после него
            // ответ был бы «да» всегда.
            let expected = lanes.firstIndex { $0 == commit.hash }
            let lane = expected ?? claim(&lanes, &colors, &nextColor)
            lanes[lane] = commit.hash

            // Сквозные линии: всё, чего ждут другие дорожки, проходит эту
            // строку насквозь. Считаются до перестройки — состояние дорожек
            // ниже изменится, а рисуется линия по тому, что было сверху.
            var links: [GraphLink] = []
            for (index, waiting) in lanes.enumerated() where index != lane && waiting != nil {
                links.append(GraphLink(from: index, to: index))
            }

            // Дорожка коммита освобождается: её займёт первый родитель, а если
            // родителей нет — она останется свободной для следующей ветки.
            lanes[lane] = nil

            for (order, parent) in commit.parents.enumerated() {
                // Родитель, которого уже ждёт другая дорожка, — это схождение:
                // новую дорожку заводить нельзя, иначе две линии шли бы к
                // одному коммиту параллельно и он оказался бы нарисован дважды.
                if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    links.append(GraphLink(from: lane, to: existing))
                    continue
                }

                let target = order == 0 ? lane : claim(&lanes, &colors, &nextColor)
                lanes[target] = parent
                links.append(GraphLink(from: lane, to: target))
            }

            rows.append(GraphRow(
                lane: lane,
                color: colors[lane],
                // Ширина по последней занятой дорожке, а не по их числу:
                // свободная дырка посередине место всё равно занимает.
                width: width(of: lanes, including: lane),
                links: links,
                hasLineAbove: expected != nil
            ))
        }

        return rows
    }

    /// Занимает свободную дорожку или заводит новую справа.
    ///
    /// Переиспользование обязательно: без него номера дорожек росли бы с каждой
    /// слитой веткой, и на истории в двести коммитов граф уехал бы далеко за
    /// край панели.
    private static func claim(_ lanes: inout [String?], _ colors: inout [Int], _ nextColor: inout Int) -> Int {
        if let free = lanes.firstIndex(where: { $0 == nil }) {
            // Цвет назначается заново: дорожка досталась другой ветке, и
            // сохранённый цвет связал бы её с предыдущей, к которой она
            // отношения не имеет.
            colors[free] = nextColor
            nextColor += 1
            return free
        }
        lanes.append(nil)
        colors.append(nextColor)
        nextColor += 1
        return lanes.count - 1
    }

    /// Сколько дорожек занято в строке, считая дорожку самого коммита.
    private static func width(of lanes: [String?], including lane: Int) -> Int {
        let lastOccupied = lanes.lastIndex { $0 != nil } ?? -1
        return max(lastOccupied, lane) + 1
    }
}
