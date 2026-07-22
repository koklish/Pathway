import Foundation
import Testing
@testable import PathwayCore

@Suite("Проба портов на реальной сети", .disabled(if: ProcessInfo.processInfo.environment["PATHWAY_NETWORK_TESTS"] == nil))
struct SocketProberLiveTests {
    @Test("хостинг с открытым FTP определяется как ftp")
    func detectsHostingFTP() async {
        let start = Date()
        let result = await ProtocolProbe().detect(host: "31.31.196.75")
        print("31.31.196.75 -> \(result ?? "nil") за \(Date().timeIntervalSince(start)) с")
        #expect(result == "ftp")
    }

    @Test("неотвечающий адрес укладывается в таймаут")
    func unreachableHostRespectsTimeout() async {
        let start = Date()
        let result = await ProtocolProbe().detect(host: "192.0.2.1")
        let elapsed = Date().timeIntervalSince(start)
        print("192.0.2.1 -> \(result ?? "nil") за \(elapsed) с")
        #expect(result == nil)
        #expect(elapsed < 2)
    }

    @Test("веб-сервер без файловых портов не определяется")
    func webServerHasNoFileProtocol() async {
        #expect(await ProtocolProbe().detect(host: "example.com") == nil)
    }
}
