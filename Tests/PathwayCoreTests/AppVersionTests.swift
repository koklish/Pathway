import Testing

@testable import PathwayCore

@Suite("Версия приложения")
struct AppVersionTests {
    @Test("сравнивает по числам, а не по строкам")
    func comparesNumerically() {
        // Строковое сравнение дало бы «1.10.0 < 1.9.0» — самая частая ошибка
        // самодельных апдейтеров: после 1.9 обновления просто перестают приходить.
        #expect(AppVersion("1.10.0")! > AppVersion("1.9.0")!)
        #expect(AppVersion("2.0.0")! > AppVersion("1.99.99")!)
    }

    @Test("одинаковые версии равны")
    func equalVersions() {
        #expect(AppVersion("1.2.3")! == AppVersion("1.2.3")!)
    }

    @Test("разбирает тег с префиксом v")
    func stripsTagPrefix() {
        #expect(AppVersion("v1.2.3")! == AppVersion("1.2.3")!)
    }

    @Test("недостающие компоненты считаются нулями")
    func missingComponentsAreZero() {
        #expect(AppVersion("1.2")! == AppVersion("1.2.0")!)
        #expect(AppVersion("1")! < AppVersion("1.0.1")!)
    }

    @Test("отвергает строку без чисел")
    func rejectsGarbage() {
        #expect(AppVersion("") == nil)
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("v") == nil)
    }

    @Test("показывается в исходном виде")
    func description() {
        #expect(AppVersion("1.2.3")!.description == "1.2.3")
        #expect(AppVersion("v1.2.3")!.description == "1.2.3")
    }
}
