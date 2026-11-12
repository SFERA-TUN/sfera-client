import SwiftUI
import NetworkExtension
import UniformTypeIdentifiers

@main
struct SferaApp: App {
    var body: some Scene {
        WindowGroup {
            ConnectionView()
                .preferredColorScheme(.dark)
        }
    }
}

@MainActor
@Observable
private final class Connection {
    var profile: Profile?
    var status: NEVPNStatus = .invalid
    var busy = false
    var error: String?
    private var manager: NETunnelProviderManager?

    private var extensionID: String {
        (Bundle.main.bundleIdentifier ?? "dev.sfera.client") + ".tunnel"
    }

    var active: Bool {
        [.connecting, .connected, .reasserting, .disconnecting].contains(status)
    }

    func load() async {
        do {
            profile = try ProfileStore.load()
            manager = try await NETunnelProviderManager.loadAllFromPreferences().first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == extensionID
            }
            refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refresh() {
        status = manager?.connection.status ?? .invalid
    }

    func importFile(_ url: URL) {
        guard !active, !busy else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let imported = try Profile.decode(file.read(upToCount: 4097) ?? Data())
            try ProfileStore.save(imported)
            profile = imported
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func toggle(directSites: DirectSites) async {
        guard !busy else { return }
        error = nil
        if active {
            manager?.connection.stopVPNTunnel()
            refresh()
            return
        }
        guard let profile else { return }
        busy = true
        defer { busy = false }
        do {
            let addresses = try await Task.detached(priority: .userInitiated) { try directSites.resolve() }.value
            let manager = self.manager ?? NETunnelProviderManager()
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = extensionID
            configuration.serverAddress = profile.host
            configuration.providerConfiguration = ["directIPv4": addresses]
            manager.protocolConfiguration = configuration
            manager.localizedDescription = "SFERA"
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            self.manager = manager
            try manager.connection.startVPNTunnel()
            refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ConnectionView: View {
    @State private var model = Connection()
    @State private var importing = false
    @State private var editingDirectSites = false
    @AppStorage("directSites.enabled") private var directSitesEnabled = false
    @AppStorage("directSites.useRussianSites") private var useRussianSites = false
    @AppStorage("directSites.custom") private var customSites = ""

    private let accent = Color(red: 0.96, green: 0.75, blue: 0.48)
    private let panel = Color(red: 0.10, green: 0.11, blue: 0.13)

    private var status: (String, String, Color) {
        switch model.status {
        case .connected: ("VPN подключён", "checkmark.shield", .green)
        case .connecting, .reasserting: ("Подключаемся…", "arrow.clockwise", accent)
        case .disconnecting: ("Отключаемся…", "power", accent)
        default: ("VPN отключён", "shield", .secondary)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("SFERA", systemImage: "shield.lefthalf.filled")
                    .font(.headline)
                    .foregroundStyle(accent)
                Text("Подключение").font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 14) {
                    Text(model.profile?.name ?? "Добавьте VPN-профиль")
                        .font(.title2.weight(.semibold))
                    Text(model.profile?.host ?? "Откройте файл SFERA, выданный владельцем сервера.")
                        .foregroundStyle(.secondary)
                    Divider()
                    Label(status.0, systemImage: status.1)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(status.2)
                    Button {
                        Task { await model.toggle(directSites: DirectSites(enabled: directSitesEnabled, useRussianSites: useRussianSites, custom: customSites)) }
                    } label: {
                        Text(model.active ? "Отключить VPN" : "Подключить VPN")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(accent)
                    .foregroundStyle(.black)
                    .disabled(model.profile == nil || model.busy || model.status == .disconnecting)
                }
                .padding(20)
                .background(panel, in: RoundedRectangle(cornerRadius: 16))
                Button("Импортировать профиль", systemImage: "square.and.arrow.down") { importing = true }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(model.active || model.busy)
                Button("Сайты без VPN", systemImage: "arrow.triangle.branch") { editingDirectSites = true }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(model.active || model.busy)
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.075, green: 0.078, blue: 0.09).ignoresSafeArea())
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url): model.importFile(url)
            case let .failure(error):
                if (error as? CocoaError)?.code != .userCancelled { model.error = error.localizedDescription }
            }
        }
        .sheet(isPresented: $editingDirectSites) { DirectSitesEditor() }
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
            model.refresh()
        }
    }
}
