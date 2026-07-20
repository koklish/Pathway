import Foundation
import Testing
@testable import PathwayCore

@MainActor
@Suite("PaneState — навигация")
struct PaneStateTests {
    let home = URL(fileURLWithPath: "/Users/alex")
    let documents = URL(fileURLWithPath: "/Users/alex/Documents")
    let projects = URL(fileURLWithPath: "/Users/alex/Documents/Projects")

    @Test("начинает с заданной папки, без возможности идти назад или вперёд")
    func startsAtInitialPath() {
        let pane = PaneState(path: home)

        #expect(pane.path == home)
        #expect(!pane.canGoBack)
        #expect(!pane.canGoForward)
    }

    @Test("переход в папку делает доступным возврат назад")
    func navigateEnablesBack() {
        let pane = PaneState(path: home)

        pane.navigate(to: documents)

        #expect(pane.path == documents)
        #expect(pane.canGoBack)
        #expect(!pane.canGoForward)
    }

    @Test("назад и вперёд ходят по истории")
    func backAndForwardWalkHistory() {
        let pane = PaneState(path: home)
        pane.navigate(to: documents)
        pane.navigate(to: projects)

        pane.goBack()
        #expect(pane.path == documents)
        #expect(pane.canGoForward)

        pane.goBack()
        #expect(pane.path == home)
        #expect(!pane.canGoBack)

        pane.goForward()
        #expect(pane.path == documents)
    }

    @Test("новый переход после возврата назад обрезает ветку вперёд")
    func navigateTruncatesForwardHistory() {
        let pane = PaneState(path: home)
        pane.navigate(to: documents)
        pane.navigate(to: projects)
        pane.goBack()

        pane.navigate(to: URL(fileURLWithPath: "/Users/alex/Downloads"))

        #expect(!pane.canGoForward)
        #expect(pane.path.lastPathComponent == "Downloads")
    }

    @Test("повторный переход в ту же папку не засоряет историю")
    func navigatingToSamePathIsNoop() {
        let pane = PaneState(path: home)
        pane.navigate(to: documents)

        pane.navigate(to: documents)
        pane.goBack()

        #expect(pane.path == home)
    }

    @Test("переход вверх ведёт в родительскую папку")
    func goUpMovesToParent() {
        let pane = PaneState(path: projects)

        pane.goUp()

        #expect(pane.path == documents)
        #expect(pane.canGoBack)
    }

    @Test("из корня вверх идти некуда")
    func goUpAtRootDoesNothing() {
        let pane = PaneState(path: URL(fileURLWithPath: "/"))

        pane.goUp()

        #expect(pane.path.path == "/")
        #expect(!pane.canGoBack)
    }

    @Test("смена папки сбрасывает выделение")
    func navigationClearsSelection() {
        let pane = PaneState(path: home)
        pane.selection = [documents]

        pane.navigate(to: documents)

        #expect(pane.selection.isEmpty)
    }
}

@MainActor
@Suite("PaneState — вырезанные файлы")
struct PaneStateCutTests {
    let file = URL(fileURLWithPath: "/Users/alex/file.txt")

    @Test("помечает файлы как вырезанные и снимает пометку")
    func marksAndClearsCutItems() {
        let pane = PaneState(path: URL(fileURLWithPath: "/Users/alex"))

        pane.markCut([file])
        #expect(pane.isCut(file))

        pane.clearCut()
        #expect(!pane.isCut(file))
    }
}
