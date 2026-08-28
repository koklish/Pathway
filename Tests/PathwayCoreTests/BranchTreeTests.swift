import Foundation
import Testing

@testable import PathwayCore

@Suite("Дерево веток по префиксам")
struct BranchTreeTests {

    private func branches(_ names: [String]) -> [Branch] {
        names.map { Branch(name: $0) }
    }

    @Test("ветка со слэшами становится вложенными папками")
    func splitsIntoFolders() throws {
        let tree = BranchTree.build(branches(["feature/SDLC/14", "feature/SDLC/35"]))

        // feature и SDLC — одна папка на двоих: единственный ребёнок-папка
        // схлопывается, иначе пришлось бы раскрывать два уровня ради одного пути.
        #expect(tree.count == 1)
        let folder = try #require(tree.first)
        #expect(folder.title == "feature/SDLC")
        #expect(folder.isFolder)
        #expect(folder.children.map(\.title) == ["14", "35"])
        #expect(folder.children.allSatisfy { !$0.isFolder })
    }

    @Test("ветка без слэша остаётся листом верхнего уровня")
    func plainBranchStaysLeaf() {
        let tree = BranchTree.build(branches(["main", "develop"]))

        #expect(tree.map(\.title) == ["main", "develop"])
        #expect(tree.allSatisfy { !$0.isFolder })
        #expect(tree.first?.branch?.name == "main")
    }

    @Test("порядок по свежести сохраняется, папка встаёт на место первой ветки")
    func keepsFreshnessOrder() {
        // Вход отсортирован git по дате: main свежее, значит стоит выше папки,
        // хотя алфавит поставил бы feature первой.
        let tree = BranchTree.build(branches(["main", "feature/A", "release-1"]))

        #expect(tree.map(\.title) == ["main", "feature", "release-1"])
    }

    @Test("папка с двумя разными ветвями не схлопывается")
    func keepsBranchingFolder() throws {
        let tree = BranchTree.build(branches(["feature/SDLC/14", "feature/COMETP/128"]))

        // Здесь у feature два ребёнка, схлопывать нечего.
        #expect(tree.count == 1)
        let folder = try #require(tree.first)
        #expect(folder.title == "feature")
        #expect(folder.children.map(\.title) == ["SDLC", "COMETP"])
        #expect(folder.children.allSatisfy { $0.isFolder })
    }

    @Test("ветка и папка с одним именем: лист важнее")
    func leafWinsOverFolder() throws {
        // git такого не допускает — «feature» и «feature/x» вместе не
        // существуют, — но если вывод такое содержит, переключаться надо на то,
        // на что можно переключиться.
        let tree = BranchTree.build(branches(["feature", "feature/A"]))

        #expect(tree.count == 1)
        let node = try #require(tree.first)
        #expect(node.isFolder == false)
        #expect(node.branch?.name == "feature")
    }

    @Test("полный путь узла сохраняется, а не только видимый хвост")
    func keepsFullPath() throws {
        let tree = BranchTree.build(branches(["feature/SDLC/14"]))

        // Путь нужен для идентификатора и для запоминания раскрытых папок:
        // хвост «14» встречается под разными префиксами.
        let leaf = try #require(tree.first?.children.first)
        #expect(leaf.path == "feature/SDLC/14")
        #expect(leaf.title == "14")
    }

    @Test("глубокая вложенность разбирается целиком")
    func handlesDeepNesting() throws {
        let tree = BranchTree.build(branches(["a/b/c/d", "a/b/c/e"]))

        let folder = try #require(tree.first)
        #expect(folder.title == "a/b/c")
        #expect(folder.children.map(\.title) == ["d", "e"])
    }

    @Test("одна ветка со слэшем даёт папку с одним листом, а не схлопывается в лист")
    func singleBranchKeepsFolder() throws {
        // Схлопывается только цепочка папок; папка с листом остаётся,
        // иначе строка «feature/A» потеряла бы признак вложенности.
        let tree = BranchTree.build(branches(["feature/A"]))

        #expect(tree.count == 1)
        let folder = try #require(tree.first)
        #expect(folder.isFolder)
        #expect(folder.children.map(\.title) == ["A"])
    }

    @Test("пустой список даёт пустое дерево")
    func emptyInputGivesEmptyTree() {
        #expect(BranchTree.build([]).isEmpty)
    }

    @Test("локальные и серверные ветки с одним именем не смешиваются")
    func keepsLocalAndRemoteSeparate() throws {
        // Дерево строится отдельно для каждой группы — сюда приходит уже
        // отобранный список, и одинаковые имена в нём означают одну ветку.
        let tree = BranchTree.build([
            Branch(name: "feature/A", isRemote: true),
            Branch(name: "feature/B", isRemote: true),
        ])

        let folder = try #require(tree.first)
        #expect(folder.children.count == 2)
        #expect(folder.children.allSatisfy { $0.branch?.isRemote == true })
    }
}
