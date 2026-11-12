import Foundation

@main
struct MacClientCheck {
    @MainActor
    static func main() throws {
        var server = VPS()
        try server.setAddress(" 203.0.113.10:2222\n")
        precondition(server.host == "203.0.113.10" && server.port == 2222)
        try server.setAddress("203.0.113.10")
        precondition(server.port == 22)
        for invalid in ["203.0.113.10:", "203.0.113.10:65536", "203.0.113.10:0", "203.0.113.999:22"] {
            do {
                try server.setAddress(invalid)
                preconditionFailure("Invalid SSH endpoint accepted")
            } catch is ClientError {}
        }
        precondition(server.port == 22)
        precondition(RuntimeStatus(state: "connecting").canStop)
        precondition(!RuntimeStatus(state: "stopping").canStop)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = folder.appendingPathComponent("client.json")
        let first = VPNProfile(version: 1, name: "First", host: "203.0.113.10", peerIP: "10.203.0.2",
                               token: String(repeating: "a", count: 64))
        let second = VPNProfile(version: 1, name: "Second", host: "203.0.113.10", peerIP: "10.203.0.6",
                                token: String(repeating: "b", count: 64))
        try JSONEncoder().encode(["profile": first]).write(to: saved)
        let model = ClientModel(savedFile: saved)
        precondition(model.profile?.id == first.id)
        let imported = folder.appendingPathComponent("import.json")
        try JSONEncoder().encode(second).write(to: imported)
        model.importProfile(imported)
        precondition(model.error == nil && model.profile?.id == second.id && model.profiles.count == 2)
        model.importProfile(imported)
        precondition(model.profiles.count == 2)
        model.selectProfile(first.id)
        let reopened = ClientModel(savedFile: saved)
        precondition(reopened.profile?.id == first.id && reopened.profiles.count == 2)
        reopened.removeProfile(first.id)
        precondition(reopened.profile?.id == second.id && reopened.profiles.count == 1)

        var directSites = DirectSites(useRussianSites: true, custom: "https://Example.org/path")
        let disabledRoutes = try directSites.resolve()
        precondition(disabledRoutes.isEmpty, "Disabled split tunneling must leave all traffic in the VPN")
        directSites.enabled = true
        let hosts = try directSites.hosts()
        precondition(hosts.contains("example.org") && hosts.contains("yandex.ru"),
                     "Re-enabling split tunneling must preserve both site lists")

        print("SSH endpoint, profile management, and split tunneling switch: OK")
    }
}
