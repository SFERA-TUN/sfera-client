import AppKit
import Foundation
import Observation

private struct SavedClient: Codable {
    var server: VPS?
    var profile: VPNProfile?
    var otherProfiles: [VPNProfile]?

    var profiles: [VPNProfile] { [profile].compactMap { $0 } + (otherProfiles ?? []) }

    mutating func activate(_ profile: VPNProfile) {
        otherProfiles = profiles.filter { $0.id != profile.id }
        self.profile = profile
    }

    mutating func remove(_ id: VPNProfile.ID) {
        let remaining = profiles.filter { $0.id != id }
        profile = remaining.first
        otherProfiles = Array(remaining.dropFirst())
    }
}

@MainActor
@Observable
final class ClientModel {
    private var saved = SavedClient()
    private var password = ""
    private let savedFile: URL
    private(set) var users: [VPNUser] = []
    private(set) var usersLoaded = false
    private(set) var activity: String?
    private(set) var identity: HostIdentity?
    private(set) var installation: ServerInstallation?
    var error: String?
    var notice: String?

    var server: VPS? { saved.server }
    var profile: VPNProfile? { saved.profile }
    var profiles: [VPNProfile] {
        saved.profiles.sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var needsPassword: Bool { server?.method == .password && password.isEmpty }

    private static var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("SFERA", isDirectory: true)
    }

    init(savedFile: URL? = nil) {
        self.savedFile = savedFile ?? Self.directory.appendingPathComponent("client.json")
        do {
            let data = try Data(contentsOf: self.savedFile)
            saved = try JSONDecoder().decode(SavedClient.self, from: data)
        } catch let failure as CocoaError where failure.code == .fileReadNoSuchFile {
            // First launch.
        } catch {
            self.error = "Не удалось открыть сохранённую конфигурацию. \(error.localizedDescription)"
        }
    }

    func resetSetup() {
        identity = nil
        installation = nil
    }

    func lookup(_ server: VPS) async {
        await work("Проверяем SSH…") {
            self.resetSetup()
            self.identity = try await ServerAccess.identify(server)
        }
    }

    func detect(server: VPS, secret: String) async -> Bool {
        await work("Проверяем, установлена ли SFERA…") {
            self.installation = try await ServerAccess.detect(server, password: secret)
            if self.installation == .ready {
                self.activity = "Получаем профиль и пользователей…"
                try await self.loadServer(server, secret: secret)
            }
        }
    }

    func install(server: VPS, secret: String, email: String) async -> Bool {
        await work("Подключаемся к VPS…") {
            let emailPattern = #"^[a-zA-Z0-9_.+%-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\z"#
            guard email.range(of: emailPattern, options: .regularExpression) != nil else {
                throw ClientError("Укажите email для выпуска сертификата.")
            }
            let architecture = try await ServerAccess.architecture(server, password: secret)
            self.activity = "Загружаем релиз из GitHub…"
            let release = try await ServerRelease.download(architecture: architecture)
            self.activity = "Устанавливаем SFERA и выпускаем TLS-сертификат…"
            try await ServerAccess.install(server, password: secret, release: release, email: email)
            try await self.loadServer(server, secret: secret)
        }
    }

    private func loadServer(_ server: VPS, secret: String) async throws {
        let list = try await fetchUsers(server, password: secret)
        guard let primary = list.first(where: \.owner) else {
            throw ClientError("Сервер не вернул основной профиль SFERA.")
        }
        let raw = try await ServerAccess.manage(server, password: secret, operation: .profile,
                                                value: primary.id.uuidString.lowercased())
        let profile = try JSONDecoder().decode(VPNProfile.self, from: raw)
        try profile.validate()
        guard profile.host == server.host else { throw ClientError("IPv4 в профиле отличается от адреса VPS.") }
        var updated = saved
        updated.server = server
        updated.activate(profile)
        try store(updated)
        password = secret
        users = list
        usersLoaded = true
        identity = nil
    }

    func importProfile(_ url: URL) {
        do {
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            let data = try input.read(upToCount: 2049) ?? Data()
            guard data.count <= 2048 else { throw ClientError("Файл профиля слишком большой.") }
            let imported = try JSONDecoder().decode(VPNProfile.self, from: data)
            try imported.validate()
            var updated = saved
            updated.activate(imported)
            try store(updated)
            notice = "Профиль добавлен"
            error = nil
        } catch {
            self.error = "Не удалось импортировать профиль. \(error.localizedDescription)"
        }
    }

    func selectProfile(_ id: VPNProfile.ID) {
        guard let profile = saved.profiles.first(where: { $0.id == id }), id != saved.profile?.id else { return }
        changeProfiles { $0.activate(profile) }
    }

    func removeProfile(_ id: VPNProfile.ID) {
        changeProfiles { $0.remove(id) }
    }

    private func changeProfiles(_ change: (inout SavedClient) -> Void) {
        do {
            var updated = saved
            change(&updated)
            try store(updated)
            error = nil
            notice = nil
        } catch {
            self.error = "Не удалось сохранить профили. \(error.localizedDescription)"
        }
    }

    func clearPassword() {
        password = ""
        users = []
        usersLoaded = false
        error = nil
        notice = nil
    }

    @discardableResult
    func refresh(secret: String? = nil) async -> Bool {
        guard let server else { return false }
        return await work("Обновляем пользователей…") {
            let candidate = secret ?? self.password
            self.users = try await self.fetchUsers(server, password: candidate)
            self.password = candidate
            self.usersLoaded = true
        }
    }

    func add(_ name: String) async -> Bool {
        guard let server else { return false }
        return await work("Создаём профиль…") {
            _ = try await ServerAccess.manage(server, password: self.password, operation: .add, value: name)
            self.notice = "Пользователь добавлен"
            do {
                self.users = try await self.fetchUsers(server, password: self.password)
            } catch {
                self.error = "Пользователь добавлен. Обновите список вручную."
            }
        }
    }

    func revoke(_ user: VPNUser) async {
        guard let server else { return }
        await work("Отзываем доступ…") {
            _ = try await ServerAccess.manage(server, password: self.password, operation: .revoke,
                                               value: user.id.uuidString.lowercased())
            self.users.removeAll { $0.id == user.id }
            self.notice = "Доступ отозван"
        }
    }

    func export(_ user: VPNUser) async {
        guard let server else { return }
        await work("Получаем профиль…") {
            let data = try await ServerAccess.manage(server, password: self.password, operation: .profile,
                                                     value: user.id.uuidString.lowercased())
            let profile = try JSONDecoder().decode(VPNProfile.self, from: data)
            try profile.validate()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "sfera-profile.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            self.notice = "Профиль сохранён"
        }
    }

    private func fetchUsers(_ server: VPS, password: String) async throws -> [VPNUser] {
        let data = try await ServerAccess.manage(server, password: password, operation: .list)
        return try JSONDecoder().decode([VPNUser].self, from: data)
    }

    private func store(_ client: SavedClient) throws {
        let manager = FileManager.default
        let directory = savedFile.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(client)
        try data.write(to: savedFile, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: savedFile.path)
        saved = client
    }

    @discardableResult
    private func work(_ message: String, _ operation: () async throws -> Void) async -> Bool {
        guard activity == nil else { return false }
        activity = message
        error = nil
        notice = nil
        defer { activity = nil }
        do {
            try await operation()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
