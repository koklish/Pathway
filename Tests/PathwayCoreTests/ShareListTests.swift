import Foundation
import Testing

@testable import PathwayCore

@Suite("Список ресурсов сервера")
struct ShareListTests {
    /// Настоящий вывод smbutil с рабочего сервера: кириллица, имя с пробелом,
    /// служебный IPC$ и выравнивание пробелами разной ширины.
    private let realOutput = """
        Share                                           Type    Comments
        -------------------------------
        Спецификации                        Disk    Спецификации
        Administrative Department                       Disk    ADepartment
        IPC$                                            Pipe    IPC Service (Samba Server 4.19.5-Ubuntu)
        MAIN                                            Disk    Common share

        4 shares listed
        """

    @Test("разбирает имена дисковых ресурсов")
    func parsesDiskShares() {
        let shares = ShareList.parse(realOutput)

        // Порядок задаёт localizedStandardCompare: в русской локали кириллица идёт первой.
        #expect(Set(shares.map(\.name)) == ["Спецификации", "Administrative Department", "MAIN"])
    }

    @Test("пропускает служебные каналы вроде IPC$")
    func skipsPipes() {
        let shares = ShareList.parse(realOutput)

        #expect(!shares.contains { $0.name == "IPC$" })
    }

    @Test("имя с пробелом не обрезается по первому пробелу")
    func keepsSpacesInName() {
        let shares = ShareList.parse(realOutput)

        #expect(shares.contains { $0.name == "Administrative Department" })
    }

    @Test("читает описание ресурса")
    func readsComment() {
        let shares = ShareList.parse(realOutput)

        let main = shares.first { $0.name == "MAIN" }
        #expect(main?.comment == "Common share")
    }

    @Test("описание, совпадающее с именем, не дублируется")
    func dropsRedundantComment() {
        let shares = ShareList.parse(realOutput)

        // «Спецификации Disk Спецификации» — комментарий не несёт информации.
        let spec = shares.first { $0.name == "Спецификации" }
        #expect(spec?.comment == nil)
    }

    @Test("пустой вывод даёт пустой список, а не ошибку")
    func handlesEmptyOutput() {
        #expect(ShareList.parse("").isEmpty)
    }

    @Test("сообщение об ошибке не превращается в ресурс")
    func ignoresErrorOutput() {
        let output = "smbutil: server connection failed: No route to host"

        #expect(ShareList.parse(output).isEmpty)
    }

    @Test("отказ авторизации не превращается в ресурс")
    func ignoresAuthError() {
        let output = "smbutil: server rejected the authentication: Authentication error"

        #expect(ShareList.parse(output).isEmpty)
    }

    @Test("ресурсы отсортированы по имени")
    func sortsByName() {
        let shares = ShareList.parse(realOutput)

        #expect(shares.map(\.name) == shares.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }
}
