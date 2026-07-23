import Foundation
import Testing
@testable import PathwayCore

@Suite("Локализованные имена системных папок")
struct SystemFolderNamesTests {

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    @Test("переводит домашние папки пользователя")
    func translatesHomeFolders() {
        #expect(SystemFolderNames.localizedName(for: home.appendingPathComponent("Desktop")) == "Рабочий стол")
        #expect(SystemFolderNames.localizedName(for: home.appendingPathComponent("Documents")) == "Документы")
        #expect(SystemFolderNames.localizedName(for: home.appendingPathComponent("Downloads")) == "Загрузки")
        #expect(SystemFolderNames.localizedName(for: home.appendingPathComponent("Pictures")) == "Изображения")
        #expect(SystemFolderNames.localizedName(for: home.appendingPathComponent("Music")) == "Музыка")
        #expect(SystemFolderNames.localizedName(for: home.appendingPathComponent("Movies")) == "Фильмы")
        #expect(SystemFolderNames.localizedName(for: home.appendingPathComponent("Applications")) == "Программы")
    }

    @Test("переводит системные каталоги")
    func translatesSystemFolders() {
        #expect(SystemFolderNames.localizedName(for: URL(fileURLWithPath: "/Applications")) == "Программы")
        #expect(SystemFolderNames.localizedName(for: URL(fileURLWithPath: "/Applications/Utilities")) == "Утилиты")
        #expect(SystemFolderNames.localizedName(for: URL(fileURLWithPath: "/System")) == "Система")
        #expect(SystemFolderNames.localizedName(for: URL(fileURLWithPath: "/Users")) == "Пользователи")
    }

    /// Ключом служит полный путь, а не только имя: иначе папка Documents
    /// внутри проекта показалась бы «Документами».
    @Test("не переводит папку с системным именем в другом месте")
    func ignoresSameNameElsewhere() {
        #expect(SystemFolderNames.localizedName(for: URL(fileURLWithPath: "/tmp/Desktop")) == nil)
        #expect(SystemFolderNames.localizedName(for: home.appendingPathComponent("Projects/Documents")) == nil)
        #expect(SystemFolderNames.localizedName(for: URL(fileURLWithPath: "/opt/Applications")) == nil)
    }

    @Test("несистемная папка перевода не получает")
    func ignoresOrdinaryFolder() {
        let url = home.appendingPathComponent("PhpstormProjects")
        #expect(SystemFolderNames.localizedName(for: url) == nil)
        #expect(SystemFolderNames.displayName(for: url) == "PhpstormProjects")
    }

    @Test("сам домашний каталог перевода не получает")
    func ignoresHomeItself() {
        #expect(SystemFolderNames.localizedName(for: home) == nil)
    }

    @Test("завершающий слэш не мешает совпадению")
    func ignoresTrailingSlash() {
        let withSlash = URL(fileURLWithPath: home.path + "/Desktop/", isDirectory: true)
        #expect(SystemFolderNames.localizedName(for: withSlash) == "Рабочий стол")
    }

    /// На регистрозависимом томе Documents и documents — разные папки,
    /// и переводить вторую значило бы подменять чужое имя.
    @Test("регистр учитывается")
    func respectsCase() {
        #expect(SystemFolderNames.localizedName(for: home.appendingPathComponent("desktop")) == nil)
    }

    @Test("displayName откатывается на имя из пути")
    func displayNameFallsBack() {
        #expect(SystemFolderNames.displayName(for: URL(fileURLWithPath: "/tmp/Отчёты")) == "Отчёты")
        #expect(SystemFolderNames.displayName(for: home.appendingPathComponent("Desktop")) == "Рабочий стол")
    }
}
