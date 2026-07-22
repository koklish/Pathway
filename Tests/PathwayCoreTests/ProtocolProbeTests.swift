import Foundation
import Testing
@testable import PathwayCore

/// Отдаёт заданный набор открытых портов и считает пробы.
///
/// `probed` копится в акторе: detect пробует порты параллельно, и обычный
/// массив здесь ловил бы гонку.
actor StubPortProber: PortProbing {
    private let open: Set<UInt16>
    private(set) var probed: [UInt16] = []

    init(open: Set<UInt16>) {
        self.open = open
    }

    func isOpen(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        probed.append(port)
        return open.contains(port)
    }
}

@Suite("Определение протокола по открытым портам")
struct ProtocolProbeTests {
    @Test("открытый 21 определяется как ftp")
    func detectsFTP() async {
        let probe = ProtocolProbe(prober: StubPortProber(open: [21]))
        #expect(await probe.detect(host: "31.31.196.75") == "ftp")
    }

    @Test("открытый 445 определяется как smb")
    func detectsSMB() async {
        let probe = ProtocolProbe(prober: StubPortProber(open: [445]))
        #expect(await probe.detect(host: "nas.local") == "smb")
    }

    @Test("открытый 548 определяется как afp")
    func detectsAFP() async {
        let probe = ProtocolProbe(prober: StubPortProber(open: [548]))
        #expect(await probe.detect(host: "mac.local") == "afp")
    }

    @Test("при нескольких открытых портах выигрывает smb, а не первый ответивший")
    func prefersSMBOverFTP() async {
        let probe = ProtocolProbe(prober: StubPortProber(open: [445, 21]))
        #expect(await probe.detect(host: "nas.local") == "smb")
    }

    @Test("afp приоритетнее ftp")
    func prefersAFPOverFTP() async {
        let probe = ProtocolProbe(prober: StubPortProber(open: [548, 21]))
        #expect(await probe.detect(host: "mac.local") == "afp")
    }

    @Test("закрытые порты не дают протокола")
    func detectsNothing() async {
        let probe = ProtocolProbe(prober: StubPortProber(open: []))
        #expect(await probe.detect(host: "example.com") == nil)
    }

    @Test("пробуются все три порта, а не по очереди до первого успеха")
    func probesAllPorts() async {
        let prober = StubPortProber(open: [445])
        _ = await ProtocolProbe(prober: prober).detect(host: "nas.local")
        #expect(Set(await prober.probed) == [445, 548, 21])
    }
}
