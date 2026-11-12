import Darwin
import Foundation
import NetworkExtension

private final class NativeSession {
    let handle: OpaquePointer
    init() { handle = sfera_session_new()! }
    deinit { sfera_session_free(handle) }

    func run(fd: Int32, profile: Profile) -> Int32 {
        sfera_session_run(handle, fd, profile.host, profile.peerIP, profile.token)
    }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let queue = DispatchQueue(label: "dev.sfera.client.tunnel.state")
    private let worker = DispatchQueue(label: "dev.sfera.client.tunnel.worker", qos: .userInitiated)
    private var generation = 0
    private var reader: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var session: NativeSession?
    private var startReply: ((Error?) -> Void)?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        queue.async {
            guard self.startReply == nil, self.session == nil else {
                completionHandler(Self.failure("Подключение уже запущено."))
                return
            }
            do {
                guard let profile = try ProfileStore.load(),
                      (self.protocolConfiguration as? NETunnelProviderProtocol)?.serverAddress == profile.host
                else { throw ProfileError.invalid }
                self.startReply = completionHandler
                self.generation += 1
                let attempt = self.generation
                self.setTunnelNetworkSettings(Self.settings(profile)) { error in
                    self.queue.async {
                        guard self.generation == attempt else { return }
                        if let error { self.end(error); return }
                        do {
                            try self.startTransport(profile)
                        } catch {
                            self.end(error)
                        }
                    }
                }
            } catch {
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            self.end(Self.failure("Подключение отменено."))
            completionHandler()
        }
    }

    private static func settings(_ profile: Profile) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: profile.host)
        let ipv4 = NEIPv4Settings(addresses: [profile.peerIP], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [.default()]
        ipv4.excludedRoutes = [NEIPv4Route(destinationAddress: profile.host, subnetMask: "255.255.255.255")]
        settings.ipv4Settings = ipv4
        // SFERA currently carries IPv4. Route IPv6 to the extension and drop it.
        let ipv6 = NEIPv6Settings(addresses: ["fd5e:fa20:fa20::2"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [.default()]
        settings.ipv6Settings = ipv6
        let dns = NEDNSSettings(servers: ["1.1.1.1", "9.9.9.9"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        settings.mtu = 1280
        return settings
    }

    private func startTransport(_ profile: Profile) throws {
        var endpoints: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &endpoints) == 0 else {
            throw Self.failure("Не удалось создать пакетный интерфейс.")
        }
        let platform = endpoints[0]
        let native = endpoints[1]
        let current = NativeSession()
        session = current
        let source = DispatchSource.makeReadSource(fileDescriptor: platform, queue: queue)
        source.setCancelHandler { close(platform) }
        source.setEventHandler { [weak self, weak current] in
            guard let self, let current, self.session === current else { return }
            self.receive(from: platform)
        }
        reader = source
        source.resume()

        let poll = DispatchSource.makeTimerSource(queue: queue)
        poll.schedule(deadline: .now() + .milliseconds(150), repeating: .milliseconds(200))
        poll.setEventHandler { [weak self, weak current] in
            guard let self, let current, self.session === current,
                  sfera_session_status(current.handle) == 1 else { return }
            let reply = self.startReply
            self.startReply = nil
            self.timer?.cancel()
            self.timer = nil
            reply?(nil)
        }
        timer = poll
        poll.resume()

        readPackets(to: platform, for: current)
        worker.async {
            let result = current.run(fd: native, profile: profile)
            close(native)
            self.queue.async {
                guard self.session === current else { return }
                let error = Self.failure("Соединение с сервером завершилось. Проверьте профиль и сеть.")
                let wasStarting = self.startReply != nil
                self.end(error)
                if !wasStarting && result != 2 { self.cancelTunnelWithError(error) }
            }
        }
    }

    private func readPackets(to descriptor: Int32, for current: NativeSession) {
        packetFlow.readPackets { [weak self, weak current] packets, protocols in
            guard let self, let current else { return }
            self.queue.async {
                guard self.session === current else { return }
                for (packet, family) in zip(packets, protocols) where family.int32Value == AF_INET {
                    _ = packet.withUnsafeBytes { bytes in
                        send(descriptor, bytes.baseAddress, bytes.count, MSG_DONTWAIT)
                    }
                }
                self.readPackets(to: descriptor, for: current)
            }
        }
    }

    private func receive(from descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var packets: [Data] = []
        for _ in 0..<64 {
            let count = buffer.withUnsafeMutableBytes { bytes in
                recv(descriptor, bytes.baseAddress, bytes.count, MSG_DONTWAIT)
            }
            guard count > 0 else { break }
            packets.append(Data(buffer.prefix(count)))
        }
        if !packets.isEmpty {
            packetFlow.writePackets(packets, withProtocols: Array(repeating: NSNumber(value: AF_INET), count: packets.count))
        }
    }

    private func end(_ error: Error) {
        generation += 1
        timer?.cancel()
        timer = nil
        reader?.cancel()
        reader = nil
        if let session { sfera_session_stop(session.handle) }
        session = nil
        let reply = startReply
        startReply = nil
        reply?(error)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "dev.sfera.client.tunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
