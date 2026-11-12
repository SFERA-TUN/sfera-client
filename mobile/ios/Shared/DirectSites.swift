import Darwin
import Foundation
import os

struct DirectSites: Codable, Sendable {
    var enabled = false
    var useRussianSites = false
    var custom = ""

    // Representative hosts from V2Fly category-ru and lib4u/amnezia-tunneling-ru.
    private static let russianSites = """
        yandex.ru ya.ru yastatic.net dzen.ru vk.com vk.ru vkvideo.ru userapi.com vkuser.net
        mail.ru imgsmail.ru ok.ru gosuslugi.ru nalog.gov.ru mos.ru sberbank.ru sber.ru
        tbank.ru tinkoff.ru alfabank.ru vtb.ru ozon.ru cdn1.ozone.ru wildberries.ru
        wbstatic.net avito.ru avito.st auto.ru 2gis.ru rutube.ru rbc.ru hh.ru
        """

    func hosts() throws -> [String] {
        let tokens = custom.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard custom.utf8.count <= 8192 else { throw Failure.tooManySites }
        let preset = useRussianSites ? Self.russianSites.split(whereSeparator: \.isWhitespace).map(String.init) : []
        let normalized = try Set((preset + tokens).map(Self.host))
        guard normalized.count <= 64 else { throw Failure.tooManySites }
        return normalized.sorted()
    }

    private static func host(_ item: String) throws -> String {
        let url = URL(string: item.contains("://") ? item : "https://" + item)
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.user == nil, url.password == nil, let hostname = url.host?.lowercased()
        else { throw Failure.invalidSite(item) }
        let host = hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.count >= 2,
              labels.allSatisfy({ label in
                  (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-" &&
                      label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              })
        else { throw Failure.invalidSite(item) }
        return host
    }

    func resolve() throws -> [String] {
        try resolve(lookup: { Self.ipv4(for: $0) })
    }

    func resolve(lookup: @escaping @Sendable (String) -> [String]) throws -> [String] {
        guard enabled else { return [] }
        let hosts = try hosts()
        guard !hosts.isEmpty else { return [] }
        let results = OSAllocatedUnfairLock(initialState: [String: [String]]())
        let workers = min(8, hosts.count)
        let work = DispatchGroup()
        let deadline = DispatchTime.now() + .seconds(12)
        for worker in 0..<workers {
            DispatchQueue.global(qos: .userInitiated).async(group: work) {
                for index in stride(from: worker, to: hosts.count, by: workers) {
                    guard DispatchTime.now() < deadline else { break }
                    let host = hosts[index]
                    let addresses = lookup(host)
                    results.withLock { $0[host] = addresses }
                }
            }
        }
        _ = work.wait(timeout: deadline)
        let resolved = results.withLock { $0 }
        let unresolved = hosts.filter { resolved[$0]?.isEmpty != false }
        guard unresolved.isEmpty else { throw Failure.unresolved(unresolved) }
        let addresses = Set(resolved.values.joined()).sorted()
        guard addresses.count <= 96 else { throw Failure.tooManyAddresses }
        return addresses
    }

    private static func ipv4(for host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var answer: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host + ".", nil, &hints, &answer) == 0, let answer else { return [] }
        defer { freeaddrinfo(answer) }
        var current: UnsafeMutablePointer<addrinfo>? = answer
        var addresses = [String]()
        while let node = current {
            current = node.pointee.ai_next
            guard let address = node.pointee.ai_addr else { continue }
            var ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            let value = UInt32(bigEndian: ip.s_addr)
            let a = value >> 24
            let b = value >> 16 & 255
            let c = value >> 8 & 255
            guard (1...223).contains(a), ![10, 127].contains(a), !(a == 100 && (64...127).contains(b)),
                  !(a == 169 && b == 254), !(a == 172 && (16...31).contains(b)),
                  !(a == 192 && (b == 168 || (b == 0 && [0, 2].contains(c)))),
                  !(a == 198 && ([18, 19].contains(b) || (b == 51 && c == 100))),
                  !(a == 203 && b == 0 && c == 113), value != 0x01010101, value != 0x09090909
            else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &ip, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                addresses.append(String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self))
            }
        }
        return addresses
    }

    enum Failure: LocalizedError {
        case invalidSite(String), tooManySites, unresolved([String]), tooManyAddresses

        var errorDescription: String? {
            switch self {
            case let .invalidSite(site): "Некорректный сайт: \(site.prefix(120))"
            case .tooManySites: "В списке может быть не более 64 сайтов, включая готовый набор."
            case let .unresolved(hosts):
                "Нет IPv4 для: \(hosts.prefix(5).joined(separator: ", "))"
                    + (hosts.count > 5 ? " и ещё \(hosts.count - 5)." : ".")
                    + " Исправьте список или отключите раздельное туннелирование."
            case .tooManyAddresses: "Найдено больше 96 IPv4-адресов. Сократите список сайтов."
            }
        }
    }
}
