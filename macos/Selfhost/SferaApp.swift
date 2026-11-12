import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Palette {
    static let background = Color(red: 19 / 255, green: 20 / 255, blue: 23 / 255)
    static let surface = Color(red: 26 / 255, green: 28 / 255, blue: 32 / 255)
    static let panel = Color(red: 35 / 255, green: 37 / 255, blue: 43 / 255)
    static let line = Color(red: 54 / 255, green: 56 / 255, blue: 62 / 255)
    static let muted = Color(red: 161 / 255, green: 161 / 255, blue: 170 / 255)
    static let action = Color(red: 228 / 255, green: 228 / 255, blue: 231 / 255)
    static let accent = Color(red: 245 / 255, green: 191 / 255, blue: 122 / 255)
}

@main
struct SferaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var tunnel = TunnelModel()
    @State private var client = ClientModel()

    var body: some Scene {
        Window("SFERA", id: "sfera-client") {
            SferaWindow(client: client, tunnel: tunnel)
                .frame(minWidth: 480, idealWidth: 580, minHeight: 520, idealHeight: 640)
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
                .onAppear {
                    AppDelegate.model = tunnel
                    tunnel.refresh()
                }
                .task {
                    while !Task.isCancelled {
                        tunnel.refresh()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 580, height: 640)
        .windowResizability(.contentMinSize)
    }
}

private enum Page {
    case home, server, setup
}

struct SferaWindow: View {
    let client: ClientModel
    @ObservedObject var tunnel: TunnelModel
    @State private var page: Page = .home
    @State private var setupOrigin: Page = .home
    @State private var importing = false

    private var mayReplaceProfile: Bool {
        !tunnel.pending && !tunnel.tunnelActive && client.activity == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch page {
                case .home:
                    ConnectionView(client: client, tunnel: tunnel, canEdit: mayReplaceProfile,
                                   openSetup: { showSetup(from: .home) }, importProfile: { importing = true })
                case .server:
                    ServerView(client: client, canSetUp: mayReplaceProfile) { showSetup(from: .server) }
                case .setup:
                    ServerSetupView(client: client, back: { navigate(setupOrigin) }) { installed in
                        navigate(installed ? .home : .server)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.background)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                client.importProfile(url)
            case let .failure(error):
                if (error as? CocoaError)?.code != .userCancelled {
                    client.error = error.localizedDescription
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text("SFERA").font(.system(size: 17, weight: .bold)).tracking(1.3)
            Spacer()
            tab("VPN", icon: "lock.shield", target: .home)
            tab("Сервер", icon: "server.rack", target: .server)
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(Palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Навигация")
    }

    private func tab(_ title: String, icon: String, target: Page) -> some View {
        let selected = page == target
        return Button {
            navigate(target)
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Palette.accent : Palette.muted)
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
        }
        .buttonStyle(SurfaceButton(fill: selected ? Palette.panel : .clear))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(client.activity != nil || page == .setup)
    }

    private func showSetup(from origin: Page) {
        guard mayReplaceProfile else { return }
        client.resetSetup()
        setupOrigin = origin
        navigate(.setup)
    }

    private func navigate(_ page: Page) {
        client.error = nil
        client.notice = nil
        self.page = page
    }
}

private struct ConnectionView: View {
    let client: ClientModel
    @ObservedObject var tunnel: TunnelModel
    let canEdit: Bool
    let openSetup: () -> Void
    let importProfile: () -> Void
    @State private var removing: VPNProfile?

    private var status: (title: String, icon: String, color: Color) {
        switch tunnel.status.state {
        case "connected": return ("VPN подключён", "checkmark.shield", .green)
        case "starting", "connecting": return ("Подключаемся", "arrow.clockwise", Palette.accent)
        case "stopping": return ("Отключаемся", "power", Palette.accent)
        case "error": return ("Соединение прервано", "exclamationmark.shield", .orange)
        default:
            return tunnel.pending
                ? ("Подключаемся", "arrow.clockwise", Palette.accent)
                : ("VPN отключён", "shield", Palette.muted)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading("Подключение")
                if let profile = client.profile {
                    profileStatus(profile)
                    HStack(spacing: 10) {
                        secondary("Импортировать профиль", icon: "square.and.arrow.down", perform: importProfile)
                        secondary("Настроить сервер", icon: "server.rack", perform: openSetup)
                    }
                    .disabled(!canEdit)
                } else {
                    welcome
                    if tunnel.status.canStop {
                        Button("Отключить VPN") { tunnel.perform("stop") }
                            .buttonStyle(PrimaryButton())
                            .disabled(tunnel.pending)
                    }
                }
                let tunnelError = client.profile == nil ? nil : (tunnel.actionError ?? tunnel.status.error)
                if let message = client.error ?? tunnelError {
                    InlineFeedback(message, icon: "exclamationmark.circle", tint: .orange)
                } else if let message = client.notice {
                    InlineFeedback(message, icon: "checkmark.circle", tint: .green)
                }
            }
            .padding(26)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .alert("Удалить профиль с этого Mac?", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        ), presenting: removing) { profile in
            Button("Удалить", role: .destructive) { if canEdit { client.removeProfile(profile.id) } }
            Button("Отмена", role: .cancel) {}
        } message: { profile in
            Text("Профиль «\(profile.name)» исчезнет из приложения.")
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "shield")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text("Добавьте VPN-подключение").font(.title2.weight(.semibold))
            Text("Настройте SFERA на своём VPS или откройте файл с готовым профилем.")
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Настроить сервер", action: openSetup).buttonStyle(PrimaryButton())
                secondary("Импортировать профиль", icon: "square.and.arrow.down", perform: importProfile)
            }
            .disabled(!canEdit)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line).allowsHitTesting(false) }
    }

    private func profileStatus(_ profile: VPNProfile) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(profile.name).font(.title2.weight(.semibold)).lineLimit(2)
                    Text(profile.host).font(.system(.callout, design: .monospaced)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Menu {
                    if client.profiles.count > 1 {
                        ForEach(client.profiles) { item in
                            Button {
                                client.selectProfile(item.id)
                            } label: {
                                if item.id == profile.id {
                                    Label("\(item.name) · \(item.host) · \(item.peerIP)", systemImage: "checkmark")
                                } else {
                                    Text("\(item.name) · \(item.host) · \(item.peerIP)")
                                }
                            }
                        }
                        Divider()
                    }
                    Button("Удалить профиль…", role: .destructive) { removing = profile }
                } label: {
                    Label("Профили", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!canEdit)
            }

            Divider().overlay(Palette.line)
            Label(status.title, systemImage: status.icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(status.color)
            if tunnel.connected {
                HStack(spacing: 14) {
                    Label(bytes(tunnel.status.rx_bytes), systemImage: "arrow.down")
                        .accessibilityLabel("Получено \(bytes(tunnel.status.rx_bytes))")
                    Label(bytes(tunnel.status.tx_bytes), systemImage: "arrow.up")
                        .accessibilityLabel("Отправлено \(bytes(tunnel.status.tx_bytes))")
                    if let rtt = tunnel.status.rtt_ms {
                        Label(String(format: "%.0f мс", rtt), systemImage: "waveform.path")
                            .accessibilityLabel(String(format: "Задержка %.0f мс", rtt))
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Palette.muted)
            }
            Button {
                toggle(profile)
            } label: {
                Text(tunnel.status.canStop ? "Отключить VPN" : "Подключить VPN")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButton())
            .disabled(tunnel.pending || tunnel.status.state == "stopping")
        }
        .padding(22)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line).allowsHitTesting(false) }
    }

    private func secondary(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
        }
        .buttonStyle(SurfaceButton(fill: Palette.panel))
    }

    private func bytes(_ value: UInt64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—"
    }

    private func toggle(_ profile: VPNProfile) {
        if tunnel.status.canStop {
            tunnel.perform("stop")
        } else {
            do {
                tunnel.perform("start", profile: try JSONEncoder().encode(profile))
            } catch {
                tunnel.actionError = "Не удалось прочитать профиль."
            }
        }
    }
}

struct InlineFeedback: View {
    let message: String
    let icon: String
    let tint: Color

    init(_ message: String, icon: String, tint: Color) {
        self.message = message
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        Label {
            Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon).accessibilityHidden(true)
        }
        .font(.callout)
        .foregroundStyle(tint)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct PageHeading: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 28, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 18)
            .frame(minHeight: 46)
            .foregroundStyle(enabled ? Palette.background : Palette.muted)
            .background(
                enabled ? Palette.accent.opacity(configuration.isPressed ? 0.8 : 1) : Palette.panel,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? Palette.accent : Palette.line, lineWidth: 1)
            }
    }
}

struct SurfaceButton: ButtonStyle {
    var fill: Color = .clear
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Palette.line : fill, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Palette.action.opacity(focused ? 1 : 0), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .opacity(enabled ? 1 : 0.55)
    }
}
