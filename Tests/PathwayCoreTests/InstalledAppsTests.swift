import Testing
@testable import PathwayCore

/// Счётчик обращений: опрос Launch Services должен случиться один раз за сессию,
/// а не на каждый вопрос — меню открывается сотни раз, приложения ставят однажды.
private final class CountingProbe: @unchecked Sendable {
    private(set) var queries: [String] = []
    let installed: Set<String>

    init(installed: Set<String>) { self.installed = installed }

    func probe(_ bundleID: String) -> Bool {
        queries.append(bundleID)
        return installed.contains(bundleID)
    }
}

@Suite("Опрос установленных приложений")
struct InstalledAppsTests {
    @Test("сообщает об установленном приложении")
    func reportsInstalled() {
        let probe = CountingProbe(installed: ["com.microsoft.Word"])
        let apps = InstalledApps(probe: probe.probe)
        #expect(apps.isInstalled(bundleID: "com.microsoft.Word"))
    }

    @Test("не сообщает о неустановленном приложении")
    func reportsMissing() {
        let probe = CountingProbe(installed: [])
        let apps = InstalledApps(probe: probe.probe)
        #expect(!apps.isInstalled(bundleID: "com.microsoft.Word"))
    }

    @Test("опрашивает систему один раз при создании, а не на каждый вопрос")
    func probesOnceAtStart() {
        let probe = CountingProbe(installed: ["com.microsoft.Word"])
        let apps = InstalledApps(probe: probe.probe)
        let afterInit = probe.queries.count

        for _ in 0..<10 {
            _ = apps.isInstalled(bundleID: "com.microsoft.Word")
            _ = apps.isInstalled(bundleID: "com.apple.iWork.Pages")
        }

        #expect(probe.queries.count == afterInit)
    }

    @Test("спрашивает ровно про приложения из реестра шаблонов")
    func asksAboutRegistryApps() {
        let probe = CountingProbe(installed: [])
        _ = InstalledApps(probe: probe.probe)
        let expected = Set(DocumentTemplates.all.compactMap(\.requiredApp))
        #expect(Set(probe.queries) == expected)
    }
}
