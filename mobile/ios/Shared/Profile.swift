import Foundation
import Security

struct Profile: Codable {
    let version: Int
    let name: String
    let host: String
    let peerIP: String
    let token: String

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096 else { throw ProfileError.invalid }
        guard let profile = try? JSONDecoder().decode(Self.self, from: data),
              profile.version == 1, !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              profile.name.utf16.count <= 120,
              let host = ipv4(profile.host), host[0] > 0, host[0] < 224,
              let peer = ipv4(profile.peerIP), peer[3] % 4 == 2,
              peer[0] == 10 || (peer[0] == 192 && peer[1] == 168) ||
                (peer[0] == 172 && (16...31).contains(peer[1])),
              profile.token.utf8.count == 64,
              profile.token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw ProfileError.invalid }
        return profile
    }

    private static func ipv4(_ value: String) -> [UInt8]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let address = parts.compactMap { part -> UInt8? in
            guard let byte = UInt8(part), String(byte) == part else { return nil }
            return byte
        }
        return parts.count == 4 && address.count == 4 ? address : nil
    }
}

enum ProfileError: LocalizedError {
    case invalid, inaccessible
    var errorDescription: String? {
        switch self {
        case .invalid: "Файл не содержит корректный профиль SFERA."
        case .inaccessible: "Не удалось получить доступ к профилю в Связке ключей."
        }
    }
}

enum ProfileStore {
    private static let profileService = "dev.sfera.client.profile"
    private static let sitesService = "dev.sfera.client.direct-sites"

    static func load() throws -> Profile? {
        try data(service: profileService).map(Profile.decode)
    }

    static func save(_ profile: Profile) throws {
        try save(JSONEncoder().encode(profile), service: profileService)
    }

    static func loadDirectSites() throws -> DirectSites? {
        try data(service: sitesService).map { try JSONDecoder().decode(DirectSites.self, from: $0) }
    }

    static func saveDirectSites(_ sites: DirectSites) throws {
        try save(JSONEncoder().encode(sites), service: sitesService)
    }

    private static func query(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "active",
        ]
    }

    private static func data(service: String) throws -> Data? {
        var item: CFTypeRef?
        var lookup = query(service: service)
        lookup[kSecReturnData as String] = true
        let result = SecItemCopyMatching(lookup as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data else { throw ProfileError.inaccessible }
        return data
    }

    private static func save(_ data: Data, service: String) throws {
        let query = query(service: service)
        let value: [String: Any] = [kSecValueData as String: data]
        let result = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if result == errSecItemNotFound {
            var item = query.merging(value) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ProfileError.inaccessible }
        } else if result != errSecSuccess {
            throw ProfileError.inaccessible
        }
    }
}
