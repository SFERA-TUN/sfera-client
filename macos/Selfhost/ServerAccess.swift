import CryptoKit
import Foundation

struct ClientError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }
}

struct VPNProfile: Codable, Identifiable {
    let version: Int
    let name: String
    let host: String
    let peerIP: String
    let token: String

    var id: String { "\(host)/\(peerIP)" }

    func validate() throws {
        guard version == 1, (1...60).contains(name.count),
              validIPv4(host), validIPv4(peerIP),
              let last = peerIP.split(separator: ".").last.flatMap({ Int($0) }), last % 4 == 2,
              token.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              token.count == 64 else {
            throw ClientError("Файл не содержит корректный профиль SFERA.")
        }
    }
}

struct VPNUser: Codable, Identifiable {
    let id: UUID
    let name: String
    let ip: String
    let owner: Bool
}

func validIPv4(_ input: String) -> Bool {
    let octets = input.split(separator: ".", omittingEmptySubsequences: false)
    return octets.count == 4 && octets.allSatisfy { part in
        guard let byte = UInt8(part) else { return false }
        return String(byte) == part
    }
}

enum SSHMethod: String, Codable, CaseIterable, Identifiable {
    case password, key
    var id: Self { self }
    var title: String { self == .password ? "Пароль" : "SSH-ключ или агент" }
}

struct VPS: Codable {
    var host = ""
    var port = 22
    var username = "root"
    var method: SSHMethod = .password
    var identityPath: String?
    var hostKey: String?

    mutating func setAddress(_ address: String) throws {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let first = parts.first, validIPv4(String(first)) else {
            throw ClientError("Введите IPv4 сервера, например 203.0.113.10:2222.")
        }
        let port = parts.count == 2 ? Int(parts[1]) : 22
        guard let port, (1...65535).contains(port) else {
            throw ClientError("Порт SSH должен быть числом от 1 до 65535.")
        }
        host = String(first)
        self.port = port
    }

    func validate() throws {
        guard validIPv4(host), (1...65535).contains(port) else {
            throw ClientError("Проверьте IPv4 сервера и порт SSH.")
        }
        guard username.count <= 32,
              username.range(of: #"^[a-z_][a-z0-9_-]*\z"#, options: .regularExpression) != nil else {
            throw ClientError("Проверьте имя пользователя SSH, например root.")
        }
    }

    var knownHost: String { port == 22 ? host : "[\(host)]:\(port)" }

    var elevated: String { username == "root" ? "" : "/usr/bin/sudo -n -- " }
}

struct HostIdentity {
    let key: String

    var fingerprint: String {
        let blob = Data(base64Encoded: key) ?? Data()
        return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

enum ServerInstallation: String, Sendable {
    case ready, absent, repair, legacy
}

struct ServerAccess: Sendable {
    enum Operation: String { case list, add, revoke, profile }

    nonisolated static func identify(_ server: VPS) async throws -> HostIdentity {
        try server.validate()
        let data = try await Task.detached {
            try run("/usr/bin/ssh-keyscan", ["-T", "6", "-t", "ed25519", "-p", String(server.port), server.host],
                    timeout: 12, failure: "Сервер не вернул ключ SSH Ed25519. Проверьте адрес и порт.")
        }.value
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count == 3, fields[0] == server.knownHost, fields[1] == "ssh-ed25519",
               let blob = Data(base64Encoded: String(fields[2])), blob.count == 51 {
                return HostIdentity(key: String(fields[2]))
            }
        }
        throw ClientError("Сервер не вернул ключ SSH Ed25519.")
    }

    static func detect(_ server: VPS, password: String) async throws -> ServerInstallation {
        let probe = """
        if [ -e /etc/systemd/system/sfera-test.service ]; then
            printf 'legacy'
        elif [ -e /etc/sfera-selfhost/public-ip ] || [ -e /opt/sfera/bin/sferactl ]; then
            if [ -x /opt/sfera/bin/sferactl ] &&
               [ -r /etc/sfera-selfhost/active/users.json ] &&
               systemctl is-active --quiet sfera-selfhost.service &&
               systemctl is-active --quiet nginx.service; then
                printf 'ready'
            else
                printf 'repair'
            fi
        else
            printf 'absent'
        fi
        """
        let command = server.elevated + "/bin/sh -c " + shellQuote(probe)
        let reply = try await execute(server, password: password, command: command)
        let status = String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let installation = ServerInstallation(rawValue: status) else {
            throw ClientError("Не удалось определить состояние SFERA на сервере.")
        }
        return installation
    }

    static func architecture(_ server: VPS, password: String) async throws -> String {
        let reply = try await execute(server, password: password, command: "/usr/bin/uname -m")
        let arch = String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["x86_64", "aarch64"].contains(arch) else {
            throw ClientError("Поддерживаются серверы Linux x86_64 и aarch64.")
        }
        return arch
    }

    static func install(_ server: VPS, password: String, release: ServerRelease, email: String) async throws {
        let script = """
        set -eu
        umask 077
        stage=$(mktemp -d /var/tmp/sfera-install.XXXXXXXX)
        trap 'rm -rf -- "$stage"' EXIT
        cd "$stage"
        cat > bundle.tar.gz
        printf '%s  %s\\n' '\(release.digest)' bundle.tar.gz | sha256sum -c - >&2
        tar -xzf bundle.tar.gz --no-same-owner --no-same-permissions
        /bin/bash install.sh \(shellQuote(server.host)) \(shellQuote(email))
        """
        let command = server.elevated + "/bin/bash -c " + shellQuote(script)
        _ = try await execute(server, password: password, command: command, input: release.payload, timeout: 480)
        let url = URL(string: "https://\(server.host)/sfera-health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (body, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.url == url,
              body == Data("sfera-selfhost-v1".utf8) else {
            throw ClientError("Сервер установлен, но HTTPS недоступен с Mac. Проверьте TCP 443 и сертификат.")
        }
    }

    static func manage(_ server: VPS, password: String, operation: Operation, value: String? = nil) async throws -> Data {
        let command = server.elevated + "/opt/sfera/bin/sferactl " + operation.rawValue
        return try await execute(server, password: password, command: command,
                                 input: try value.map { try JSONEncoder().encode($0) })
    }

    static func execute(_ server: VPS, password: String, command: String, input: Data? = nil,
                        timeout: TimeInterval = 35) async throws -> Data {
        try server.validate()
        guard let key = server.hostKey, let blob = Data(base64Encoded: key), blob.count == 51 else {
            throw ClientError("Подтвердите ключ SSH сервера.")
        }
        return try await Task.detached {
            let directory = try privateDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let known = directory.appendingPathComponent("known_hosts")
            try Data("\(server.knownHost) ssh-ed25519 \(key)\n".utf8).write(to: known)
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"
            var arguments = ["-F", "/dev/null", "-T", "-p", String(server.port),
                             "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=10",
                             "-o", "ServerAliveCountMax=3", "-o", "GlobalKnownHostsFile=/dev/null",
                             "-o", "UserKnownHostsFile=\(known.path)", "-o", "StrictHostKeyChecking=yes",
                             "-o", "HostKeyAlgorithms=ssh-ed25519", "-o", "UpdateHostKeys=no",
                             "-l", server.username]
            switch server.method {
            case .password:
                guard !password.isEmpty, !password.contains(where: \.isNewline), !password.contains("\0") else {
                    throw ClientError("Введите пароль SSH.")
                }
                let secret = directory.appendingPathComponent("password")
                let askpass = directory.appendingPathComponent("askpass")
                try Data(password.utf8).write(to: secret)
                try Data("#!/bin/sh\nexec /bin/cat \"$SFERA_SSH_PASSWORD_FILE\"\n".utf8).write(to: askpass)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
                environment["SSH_ASKPASS"] = askpass.path
                environment["SSH_ASKPASS_REQUIRE"] = "force"
                environment["SFERA_SSH_PASSWORD_FILE"] = secret.path
                arguments += ["-o", "PreferredAuthentications=password,keyboard-interactive",
                              "-o", "NumberOfPasswordPrompts=1"]
            case .key:
                arguments += ["-o", "BatchMode=yes", "-o", "PreferredAuthentications=publickey"]
                if let identity = server.identityPath {
                    arguments += ["-o", "IdentitiesOnly=yes", "-i", identity]
                }
            }
            arguments += ["--", server.host, command]
            return try run("/usr/bin/ssh", arguments, input: input, environment: environment, timeout: timeout)
        }.value
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func privateDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sfera-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return path
    }

    private static func run(_ executable: String, _ arguments: [String], input: Data? = nil,
                            environment: [String: String]? = nil, timeout: TimeInterval,
                            failure: String? = nil) throws -> Data {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output")
        let errors = directory.appendingPathComponent("errors")
        try Data().write(to: output)
        try Data().write(to: errors)
        let outputHandle = try FileHandle(forWritingTo: output)
        let errorHandle = try FileHandle(forWritingTo: errors)
        defer { try? outputHandle.close(); try? errorHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        let inputHandle: FileHandle
        if let input {
            let source = directory.appendingPathComponent("input")
            try input.write(to: source)
            inputHandle = try FileHandle(forReadingFrom: source)
        } else {
            inputHandle = .nullDevice
        }
        defer { if input != nil { try? inputHandle.close() } }
        process.standardInput = inputHandle

        let complete = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in complete.signal() }
        try process.run()
        if complete.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw ClientError("Сервер не ответил вовремя. Проверьте соединение и повторите.")
        }
        guard process.terminationStatus == 0 else {
            let log = try FileHandle(forReadingFrom: errors)
            defer { try? log.close() }
            let size = try log.seekToEnd()
            try log.seek(toOffset: size > 4096 ? size - 4096 : 0)
            let details = String(decoding: try log.read(upToCount: 4096) ?? Data(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if details.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
                throw ClientError("Ключ SSH изменился. Проверьте новый отпечаток через консоль VPS.")
            }
            if details.contains("sudo:") {
                throw ClientError("Для управления SFERA войдите как root или разрешите этой учётной записи sudo без пароля.")
            }
            if details.contains("Permission denied") {
                throw ClientError("SSH отклонил вход. Проверьте имя пользователя, пароль или ключ.")
            }
            throw ClientError(failure ?? (details.isEmpty ? "Команда на сервере завершилась ошибкой." : details))
        }
        let result = try FileHandle(forReadingFrom: output)
        defer { try? result.close() }
        let data = try result.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536 else { throw ClientError("Ответ сервера слишком большой.") }
        return data
    }
}

struct ServerRelease: Sendable {
    // Set to the official server repository as "owner/repo".
    static let repository: String? = "SFERA-TUN/sfera-server"

    private struct Release: Decodable {
        let tag_name: String
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let size: Int
        let digest: String?
        let browser_download_url: URL
    }

    let digest: String
    let payload: Data

    static func download(architecture: String) async throws -> Self {
        guard let repository else {
            throw ClientError("Источник серверных релизов ещё не задан в этой сборке.")
        }
        let repoPattern = #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}\z"#
        guard repository.range(of: repoPattern, options: .regularExpression) != nil,
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw ClientError("В коде указан некорректный адрес репозитория сервера.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (json, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ClientError("GitHub не вернул официальный релиз SFERA.")
        }
        let release = try JSONDecoder().decode(Release.self, from: json)
        let filename = "sfera-server-linux-\(architecture)-v1.tar.gz"
        guard release.tag_name.hasPrefix("server-v"),
              let asset = release.assets.first(where: { $0.name == filename }),
              let digest = asset.digest,
              digest.range(of: #"^sha256:[0-9a-f]{64}\z"#, options: .regularExpression) != nil,
              (1...50_000_000).contains(asset.size), asset.browser_download_url.scheme == "https",
              asset.browser_download_url.host == "github.com" else {
            throw ClientError("В последнем релизе отсутствует совместимый пакет \(filename) с SHA-256.")
        }
        let (download, downloadResponse) = try await URLSession.shared.download(from: asset.browser_download_url)
        let file = try FileHandle(forReadingFrom: download)
        defer { try? file.close() }
        guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200,
              try file.seekToEnd() == UInt64(asset.size) else {
            throw ClientError("Размер загруженного пакета отличается от GitHub Releases.")
        }
        try file.seek(toOffset: 0)
        let payload = try file.readToEnd() ?? Data()
        let expected = String(digest.dropFirst(7))
        let actual = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        guard expected == actual else { throw ClientError("SHA-256 пакета не совпадает с GitHub Releases.") }
        return Self(digest: expected, payload: payload)
    }
}
