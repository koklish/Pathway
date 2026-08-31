import Foundation
import Testing

@testable import PathwayCore

/// Корень репозитория проекта: три уровня вверх от этого файла.
/// Снаружи сьюта — условие .enabled ссылалось бы на его же статик, а это
/// циклическая ссылка, и макрос @Suite не разворачивается вовсе.
private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

/// Прогон по репозиторию самого проекта: истории с настоящими слияниями,
/// тегами и русскими сообщениями синтетика не заменяет.
///
/// Включается только когда репозиторий на месте: на машине коллеги, собравшего
/// исходники из архива, .git может не быть вовсе.
@Suite("Настоящая история проекта", .enabled(if: GitRepository.isRepository(projectRoot)))
struct RealRepoSmokeTests {

    @Test("история проекта разбирается и укладывается без пропусков")
    func parsesOwnHistory() async throws {
        let commits = try await GitService().log(at: projectRoot, limit: 100)

        #expect(commits.count > 10)
        // Хеш обязан быть полным: короткий не годится для git show.
        #expect(commits.allSatisfy { $0.hash.count == 40 })
        // Сообщение непустое у всех: пустое означало бы съехавшие поля разбора.
        #expect(commits.allSatisfy { !$0.subject.isEmpty })
        // Даты убывают: --date-order обязан отдать ленту сверху вниз.
        #expect(zip(commits, commits.dropFirst()).allSatisfy { $0.date >= $1.date })

        let rows = GitGraph.build(commits)
        #expect(rows.count == commits.count)
        // Дорожек немного: в этом проекте история почти линейна, и разъехавшийся
        // граф означал бы, что дорожки не переиспользуются.
        #expect(rows.map(\.width).max() ?? 0 <= 4)
    }

    @Test("в графе настоящей истории нет разрывов")
    func realHistoryHasNoBreaks() async throws {
        let commits = try await GitService().log(at: projectRoot, limit: 100)
        let rows = GitGraph.build(commits)

        // Каждая точка обязана быть соединена с историей: либо линией сверху,
        // либо она первая в своей ветке и начинается кривой из строки выше.
        for index in rows.indices.dropFirst() {
            let above = rows[index - 1]
            let current = rows[index]
            let connected = current.hasLineAbove
                || above.links.contains { $0.to == current.lane }
            #expect(connected, "точка в строке \(index) не соединена с историей")
        }

        // И обратно: линия, ушедшая вниз, обязана быть подхвачена следующей
        // строкой — иначе она обрывается в воздухе.
        for index in rows.indices.dropLast() {
            let current = rows[index]
            let below = rows[index + 1]
            for link in current.links {
                let picked = below.lane == link.to
                    || below.links.contains { $0.from == link.to }
                    || (below.hasLineAbove && below.lane == link.to)
                #expect(picked, "линия \(link.from)→\(link.to) из строки \(index) обрывается")
            }
        }
    }

    @Test("текущая ветка помечена как HEAD")
    func marksHead() async throws {
        let commits = try await GitService().log(at: projectRoot, limit: 5)
        let head = commits.flatMap(\.refs).first { $0.kind == .head }

        // Без этой пометки панель не смогла бы показать «вы здесь».
        #expect(head != nil)
    }

    @Test("файлы последнего коммита читаются")
    func readsFilesOfLatestCommit() async throws {
        let service = GitService()
        let commits = try await service.log(at: projectRoot, limit: 1)
        let files = try await service.files(of: commits[0].hash, at: projectRoot)

        #expect(!files.isEmpty)
        #expect(files.allSatisfy { !$0.path.isEmpty })
    }
}
