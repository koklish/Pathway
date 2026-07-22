import Darwin
import Foundation

/// Проверяет порт неблокирующим connect.
///
/// Не URLSession и не Network.framework: нужен факт «порт принимает
/// соединение», а не рукопожатие протокола. connect отвечает на это дешевле
/// всего — по FTP рукопожатие потребовало бы ещё и разбора приветствия.
public struct SocketProber: PortProbing {
    public init() {}

    public func isOpen(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            // Резолв имени блокирующий, поэтому весь замер уходит с вызывающего
            // потока: detect пробует три порта разом и не должен ждать DNS.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.probe(host: host, port: port, timeout: timeout))
            }
        }
    }

    private static func probe(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let list else { return false }
        defer { freeaddrinfo(list) }

        // Хост может отдать и IPv6, и IPv4: успех любого адреса значит,
        // что порт открыт.
        var candidate: UnsafeMutablePointer<addrinfo>? = list
        while let info = candidate {
            if connects(to: info.pointee, timeout: timeout) { return true }
            candidate = info.pointee.ai_next
        }
        return false
    }

    private static func connects(to info: addrinfo, timeout: TimeInterval) -> Bool {
        let descriptor = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        // Неблокирующий режим: иначе connect к неотвечающему хосту висит
        // десятками секунд системного таймаута, мимо нашего.
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }

        let result = connect(descriptor, info.ai_addr, info.ai_addrlen)
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var descriptors = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptors, 1, Int32(timeout * 1000)) > 0 else { return false }

        // Сокет становится доступным на запись и при отказе тоже —
        // отличить успех от ECONNREFUSED можно только по SO_ERROR.
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else { return false }
        return error == 0
    }
}
