import AppKit
import Combine
import SwiftUI

@MainActor private let statusTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

struct RuntimeStatus: Decodable, Equatable {
    var state: String?
    var interface: String?
    var tunnel_ip: String?
    var rtt_ms: Double?
    var tx_bytes: UInt64?
    var rx_bytes: UInt64?
    var error: String?

    var isActive: Bool {
        ["starting", "connecting", "connected", "stopping"].contains(state ?? "")
    }

    var canStop: Bool { isActive && state != "stopping" }
}

@MainActor
final class TunnelModel: ObservableObject {
    @Published var status = RuntimeStatus()
    @Published var pending = false
    @Published var actionError: String?

    private var isQuitting = false
    private var waitingForQuitDisconnect = false
    private var quitDeadline: Date?

    var connected: Bool { status.state == "connected" }
    var tunnelActive: Bool { status.isActive }
    var statusURL: URL { Self.supportRoot.appendingPathComponent("runtime/status.json") }
    private var heartbeatURL: URL { Self.supportRoot.appendingPathComponent("runtime/heartbeat") }
    var logDirectory: URL { Self.supportRoot.appendingPathComponent("runtime", isDirectory: true) }

    private static var supportRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SFERA Test", isDirectory: true)
    }

    func refresh() {
        let snapshot = (try? Data(contentsOf: statusURL))
            .flatMap { try? JSONDecoder().decode(RuntimeStatus.self, from: $0) }
        if let snapshot, snapshot != status {
            status = snapshot
        } else if snapshot == nil, !pending, !FileManager.default.fileExists(atPath: statusURL.path),
                  status != RuntimeStatus() {
            status = RuntimeStatus()
        }
        if status.state == "starting" || status.state == "connecting" || connected { touchHeartbeat() }
        if isQuitting && waitingForQuitDisconnect {
            if !tunnelActive {
                waitingForQuitDisconnect = false
                isQuitting = false
                NSApp.reply(toApplicationShouldTerminate: true)
            } else if let quitDeadline, Date() >= quitDeadline {
                waitingForQuitDisconnect = false
                isQuitting = false
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
    }

    func perform(_ action: String, profile: Data? = nil, directSites: DirectSites = DirectSites()) {
        guard !pending else { return }
        if action == "stop", !tunnelActive { return }
        pending = true
        actionError = nil
        if action == "start", !prepareRuntimeDirectory() { pending = false; return }

        Task {
            let result: String?
            do {
                let payload = try await Task.detached(priority: .userInitiated) {
                    guard let profile, action == "start" else { return profile }
                    let addresses = try directSites.resolve()
                    guard !addresses.isEmpty,
                          var message = try JSONSerialization.jsonObject(with: profile) as? [String: Any]
                    else { return profile }
                    message["directIPv4"] = addresses
                    return try JSONSerialization.data(withJSONObject: message)
                }.value
                if isQuitting && action == "start" {
                    result = nil
                } else {
                    result = await Task.detached(priority: .userInitiated) {
                        Self.runHelper(action: action, profile: payload)
                    }.value
                }
            } catch {
                result = error.localizedDescription
            }
            pending = false
            if let result { actionError = result }
            refresh()
            if isQuitting {
                if action == "stop" {
                    if result != nil {
                        isQuitting = false
                        NSApp.reply(toApplicationShouldTerminate: false)
                    } else if tunnelActive {
                        waitingForQuitDisconnect = true
                        quitDeadline = Date().addingTimeInterval(30)
                    } else {
                        isQuitting = false
                        NSApp.reply(toApplicationShouldTerminate: true)
                    }
                } else if tunnelActive {
                    perform("stop")
                } else {
                    isQuitting = false
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }
    }

    func quitAndDisconnect() {
        isQuitting = true
        if pending { return }
        if tunnelActive { perform("stop") }
        else { NSApp.reply(toApplicationShouldTerminate: true) }
    }

    private func prepareRuntimeDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logDirectory.path)
            _ = FileManager.default.createFile(atPath: heartbeatURL.path, contents: Data())
            touchHeartbeat()
            return true
        } catch {
            actionError = "Не удалось подготовить каталог состояния: \(error.localizedDescription)"
            return false
        }
    }

    private func touchHeartbeat() {
        if !FileManager.default.fileExists(atPath: heartbeatURL.path) {
            _ = FileManager.default.createFile(atPath: heartbeatURL.path, contents: Data())
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: heartbeatURL.path)
    }

    nonisolated private static func runHelper(action: String, profile: Data?) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        if action == "stop" {
            process.arguments = ["-I", "-B"] + helperArguments(action: action)
        } else if let resources = Bundle.main.resourceURL {
            process.arguments = ["-I", "-B", resources.appendingPathComponent("service-helper.py").path,
                                 "connect", resources.path]
        } else {
            return "Ресурсы SFERA недоступны."
        }
        if profile != nil, action == "start" {
            process.arguments?.append("--profile")
        }
        return run(process: process, input: profile)
    }

    nonisolated private static func helperArguments(action: String) -> [String] {
        let resources = Bundle.main.resourceURL?.path ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [resources + "/root-helper.py", action, "--resources", resources,
                "--user-home", home, "--user-uid", String(getuid())]
    }

    nonisolated private static func run(process: Process, input: Data?) -> String? {
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let standardInput = input.map { _ in Pipe() }
        process.standardInput = (standardInput as Any?) ?? FileHandle.nullDevice
        do {
            try process.run()
            if let input, let standardInput {
                try standardInput.fileHandleForWriting.write(contentsOf: input)
                try standardInput.fileHandleForWriting.close()
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return message?.isEmpty == false ? message : "Не удалось выполнить команду."
            }
            return nil
        } catch {
            return "Не удалось запустить команду: \(error.localizedDescription)"
        }
    }
}

struct SferaTestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = TunnelModel()

    var body: some Scene {
        WindowGroup {
            MainView(model: model)
                .frame(width: 420)
                .onReceive(statusTimer) { _ in model.refresh() }
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: TunnelModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        guard model.pending || model.tunnelActive else { return .terminateNow }
        model.quitAndDisconnect()
        return .terminateLater
    }
}

struct MainView: View {
    @ObservedObject var model: TunnelModel

    init(model: TunnelModel) {
        self.model = model
        AppDelegate.model = model
    }

    private var stateTitle: String {
        switch model.status.state {
        case "connected": return "Подключено"
        case "connecting", "starting": return "Подключение…"
        case "stopping": return "Отключение…"
        case "error": return "Ошибка"
        default: return "Отключено"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "network")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 48, height: 48)
                    .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("SFERA Test").font(.title2.weight(.semibold))
                    Text("Экспериментальный IPv4-тест")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(spacing: 0) {
                infoRow("Сервер", value: "192.0.2.1")
                Divider().padding(.leading, 14)
                infoRow("Состояние", value: stateTitle, indicator: model.connected)
                if let interface = model.status.interface, !interface.isEmpty {
                    Divider().padding(.leading, 14)
                    infoRow("Интерфейс", value: interface)
                }
                if let tunnelIP = model.status.tunnel_ip, !tunnelIP.isEmpty {
                    Divider().padding(.leading, 14)
                    infoRow("IP туннеля", value: tunnelIP)
                }
                if let rtt = model.status.rtt_ms {
                    Divider().padding(.leading, 14)
                    infoRow("Задержка", value: String(format: "%.1f мс", rtt))
                }
                if model.status.tx_bytes != nil || model.status.rx_bytes != nil {
                    Divider().padding(.leading, 14)
                    infoRow("Передано / получено", value: "\(formatBytes(model.status.tx_bytes ?? 0)) / \(formatBytes(model.status.rx_bytes ?? 0))")
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))

            if let error = model.actionError ?? model.status.error, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack(spacing: 10) {
                Button {
                    model.perform("start")
                } label: {
                    if model.pending { ProgressView().controlSize(.small) }
                    Text("Подключить")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.pending || model.tunnelActive)

                Button("Отключить") { model.perform("stop") }
                    .buttonStyle(.bordered)
                    .disabled(model.pending || !model.tunnelActive)

                Spacer()
                Button("Журнал") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.logDirectory])
                }
                .buttonStyle(.link)
            }

            Text("Тестовый режим. Только IPv4. Не заявляет обход DPI.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .onAppear { model.refresh() }
    }

    private func infoRow(_ title: String, value: String, indicator: Bool? = nil) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            if let indicator {
                Circle().fill(indicator ? Color.green : Color.secondary).frame(width: 8, height: 8)
            }
            Text(value).fontWeight(.medium).textSelection(.enabled)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

#if !SFERA_SELFHOST
@main
enum SferaTestMain {
    static func main() {
        SferaTestApp.main()
    }
}
#endif
