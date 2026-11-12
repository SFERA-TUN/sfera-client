import AppKit
import SwiftUI

struct ServerView: View {
    let client: ClientModel
    let canSetUp: Bool
    let openSetup: () -> Void
    @State private var adding = false
    @State private var confirmingUpdate = false
    @State private var name = ""
    @State private var secret = ""
    @State private var revokeUser: VPNUser?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                PageHeading("Мой сервер")
                if let server = client.server {
                    Label(server.host, systemImage: "server.rack")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                    if !client.needsPassword { versionContent }
                    usersContent
                    if let error = client.error {
                        InlineFeedback(error, icon: "exclamationmark.circle", tint: .orange)
                    }
                } else {
                    Text("Добавьте VPS, чтобы управлять пользователями и выдавать профили.")
                        .font(.callout)
                        .foregroundStyle(Palette.muted)
                    Button("Настроить сервер", action: openSetup)
                        .buttonStyle(PrimaryButton())
                        .disabled(!canSetUp)
                }
            }
            .padding(26)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .task {
            if client.server != nil && !client.needsPassword && !client.usersLoaded {
                await client.refresh()
            }
        }
        .sheet(isPresented: $adding) {
            VStack(alignment: .leading, spacing: 17) {
                Text("Добавить пользователя").font(.title2.weight(.semibold))
                Text("Для пользователя будет создан отдельный профиль доступа.")
                    .foregroundStyle(Palette.muted)
                TextField("Имя пользователя", text: $name)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Отмена", role: .cancel) {
                        adding = false
                        name = ""
                        client.error = nil
                    }.keyboardShortcut(.cancelAction)
                    Button("Добавить") {
                        Task {
                            if await client.add(name) {
                                name = ""
                                adding = false
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let activity = client.activity {
                    ProgressLabel(text: activity)
                } else if let error = client.error {
                    InlineFeedback(error, icon: "exclamationmark.circle", tint: .orange)
                }
            }
            .padding(24)
            .frame(width: 340)
            .presentationBackground(Palette.surface)
            .disabled(client.activity != nil)
        }
        .confirmationDialog("Обновить сервер SFERA?", isPresented: $confirmingUpdate,
                            presenting: client.serverUpdate) { update in
            Button("Обновить до \(update.target)") {
                Task { await client.updateServer() }
            }
        } message: { _ in
            Text("Существующие пользователи и ключи сохранятся. Активные VPN-подключения ненадолго прервутся.")
        }
        .confirmationDialog("Отозвать VPN-доступ?", isPresented: Binding(
            get: { revokeUser != nil }, set: { if !$0 { revokeUser = nil } }
        ), presenting: revokeUser) { user in
            Button("Отозвать доступ", role: .destructive) {
                Task { await client.revoke(user) }
            }
        } message: { user in
            Text("Профиль «\(user.name)» перестанет работать. При обновлении настроек сервер перезапустит активные подключения.")
        }
    }

    private var versionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Версия сервера").font(.headline)
            if let version = client.installedServerVersion {
                Text(version == "unversioned" ? "Установка без номера версии" : version)
                    .foregroundStyle(Palette.muted)
            }
            if let update = client.serverUpdate {
                Button("Обновить до \(update.target)", systemImage: "arrow.down.circle") {
                    confirmingUpdate = true
                }
                .buttonStyle(PrimaryButton())
            } else {
                Button("Проверить обновления", systemImage: "arrow.clockwise") {
                    Task { await client.checkServerUpdate() }
                }
            }
        }
        .disabled(client.activity != nil)
    }

    private var usersContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider().overlay(Palette.line)
            HStack {
                Text("Пользователи").font(.title3.weight(.semibold))
                Spacer()
                Button("Обновить", systemImage: "arrow.clockwise") {
                    Task { await client.refresh() }
                }
                .labelStyle(.iconOnly)
                .frame(width: 32, height: 32)
                .help("Обновить список")
                .disabled(client.needsPassword)
                Button("Добавить", systemImage: "plus") {
                    client.error = nil
                    adding = true
                }
                    .buttonStyle(PrimaryButton())
                    .disabled(client.needsPassword || !client.usersLoaded)
            }
            if client.needsPassword {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Введите пароль SSH, чтобы управлять пользователями.").foregroundStyle(Palette.muted)
                    HStack {
                        SecureField("Пароль SSH", text: $secret)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(unlock)
                        Button("Открыть доступ", action: unlock)
                            .disabled(secret.isEmpty)
                    }
                }
                .padding(16)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
            } else if client.usersLoaded {
                VStack(spacing: 0) {
                    ForEach(client.users) { user in
                        UserRow(user: user, export: { Task { await client.export(user) } },
                                revoke: { revokeUser = user })
                        if user.id != client.users.last?.id { Divider().overlay(Palette.line) }
                    }
                }
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                Text("Добавление и отзыв доступа перезапускают VPN-службу.")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            if let activity = client.activity {
                ProgressLabel(text: activity)
            } else if let notice = client.notice {
                Label(notice, systemImage: "checkmark.circle").foregroundStyle(Palette.accent)
            }
            HStack(spacing: 15) {
                Button("Настроить другой сервер", action: openSetup)
                    .buttonStyle(.link)
                    .disabled(!canSetUp)
                if client.server?.method == .password, !client.needsPassword {
                    Button("Ввести пароль заново") { client.clearPassword() }
                        .buttonStyle(.link)
                }
            }
        }
        .disabled(client.activity != nil)
    }

    private func unlock() {
        guard !secret.isEmpty else { return }
        Task { if await client.refresh(secret: secret) { secret = "" } }
    }
}

private struct UserRow: View {
    let user: VPNUser
    let export: () -> Void
    let revoke: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: user.owner ? "laptopcomputer" : "person")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.action)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(user.name).font(.callout.weight(.semibold)).lineLimit(1)
                Text(user.ip).font(.system(.caption, design: .monospaced)).foregroundStyle(Palette.muted)
            }
            Spacer()
            Menu("Действия", systemImage: "ellipsis.circle") {
                Button("Сохранить профиль…", systemImage: "square.and.arrow.down", action: export)
                if !user.owner {
                    Button("Отозвать доступ…", systemImage: "trash", role: .destructive, action: revoke)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Действия для \(user.name)")
        }
        .padding(11)
    }
}

struct ServerSetupView: View {
    let client: ClientModel
    let back: () -> Void
    let ready: (Bool) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button(action: back) {
                    Label("Назад", systemImage: "arrow.left")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                }
                .buttonStyle(SurfaceButton())
                .disabled(client.activity != nil)

                PageHeading("Настройка сервера")
                Text("SFERA подключится по SSH и проверит, установлена ли VPN-служба.")
                    .foregroundStyle(Palette.muted)
                SetupForm(client: client, ready: ready)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 26)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct SetupForm: View {
    let client: ClientModel
    let ready: (Bool) -> Void
    @State private var server = VPS()
    @State private var address = ""
    @State private var password = ""
    @State private var email = ""
    @State private var confirming = false
    @State private var showingInstall = false
    @State private var showPassword = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case address, username, password
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                field("IPv4 сервера и порт", focused: focus == .address) {
                    TextField("203.0.113.10:2222", text: $address)
                        .focused($focus, equals: .address)
                }
                field("Пользователь SSH", focused: focus == .username) {
                    TextField("root", text: $server.username)
                        .focused($focus, equals: .username)
                }
                .frame(width: 145)
            }
            Text("Без порта используется 22. Нужен root или sudo без пароля.")
                .font(.caption)
                .foregroundStyle(Palette.muted)
            Picker("Вход по SSH", selection: $server.method) {
                ForEach(SSHMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .labelsHidden()

            if server.method == .password {
                HStack(spacing: 0) {
                    field("Пароль SSH", focused: focus == .password) {
                        if showPassword {
                            TextField("Введите пароль", text: $password)
                                .focused($focus, equals: .password)
                        } else {
                            SecureField("Введите пароль", text: $password)
                                .focused($focus, equals: .password)
                        }
                    }
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Palette.background)
                            .frame(width: 48, height: 60)
                            .background(Palette.action)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showPassword ? "Скрыть пароль" : "Показать пароль")
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(server.identityPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Используется SSH-агент")
                        .font(.callout)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                    HStack {
                        Button("Выбрать ключ…", action: pickKey)
                        if server.identityPath != nil {
                            Button("Убрать ключ") { server.identityPath = nil }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
            }

            if let error = client.error {
                InlineFeedback(error, icon: "exclamationmark.circle", tint: .orange)
            }
            if let activity = client.activity {
                ProgressLabel(text: activity)
            } else {
                installationResult
            }
            Button(action: checkServer) {
                Text("Проверить сервер").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButton())
        }
        .disabled(client.activity != nil)
        .onSubmit(checkServer)
        .onChange(of: address) { clearResult() }
        .onChange(of: server.username) { clearResult() }
        .onChange(of: server.method) { clearResult() }
        .onChange(of: server.identityPath) { clearResult() }
        .onChange(of: password) { clearResult() }
        .sheet(isPresented: $confirming) {
            VStack(alignment: .leading, spacing: 15) {
                Text("Подтвердите ключ SSH").font(.title2.weight(.semibold))
                Text("Сравните отпечаток с ключом Ed25519 в консоли VPS.")
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(client.identity?.fingerprint ?? "")
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("Отмена", role: .cancel) { confirming = false }.keyboardShortcut(.cancelAction)
                    Button("Доверять и проверить") {
                        server.hostKey = client.identity?.key
                        confirming = false
                        detect()
                    }
                    .buttonStyle(PrimaryButton())
                }
            }
            .padding(25)
            .frame(width: 350)
            .presentationBackground(Palette.surface)
        }
        .sheet(isPresented: $showingInstall) { installSheet }
    }

    @ViewBuilder
    private var installationResult: some View {
        switch client.installation {
        case .legacy:
            InlineFeedback("На сервере найдена тестовая SFERA. Чтобы управлять пользователями, сначала перенесите сервер на self-hosted версию.",
                           icon: "info.circle", tint: Palette.muted)
        case .absent, .repair:
            let state = client.installation == .repair
                ? "Файлы SFERA найдены, но служба недоступна."
                : "На сервере ещё нет SFERA."
            VStack(alignment: .leading, spacing: 8) {
                InlineFeedback(state, icon: "server.rack", tint: Palette.accent)
                if ServerRelease.repository == nil {
                    Text("Установка станет доступна после публикации серверного релиза.")
                        .font(.callout)
                        .foregroundStyle(Palette.muted)
                } else {
                    Button(client.installation == .repair ? "Восстановить SFERA…" : "Установить SFERA…") {
                        showingInstall = true
                    }
                    .buttonStyle(.bordered)
                }
            }
        default:
            EmptyView()
        }
    }

    private func clearResult() {
        client.resetSetup()
        client.error = nil
    }

    private func checkServer() {
        guard client.activity == nil else { return }
        client.resetSetup()
        var candidate = server
        do {
            try candidate.setAddress(address)
        } catch {
            focus = .address
            client.error = error.localizedDescription
            return
        }
        candidate.username = server.username.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try candidate.validate()
        } catch {
            focus = .username
            client.error = error.localizedDescription
            return
        }
        if server.method == .password && password.isEmpty {
            focus = .password
            client.error = "Введите пароль SSH или выберите вход по ключу."
            return
        }
        focus = nil
        showPassword = false
        Task {
            await client.lookup(candidate)
            guard let identity = client.identity else { return }
            let savedServer = client.server
            let knownKey = candidate.host == savedServer?.host && candidate.port == savedServer?.port
                ? savedServer?.hostKey
                : nil
            let checkedKey = candidate.host == server.host && candidate.port == server.port ? server.hostKey : nil
            server.host = candidate.host
            server.port = candidate.port
            if knownKey == identity.key || checkedKey == identity.key {
                server.hostKey = identity.key
                detect()
            } else {
                server.hostKey = nil
                confirming = true
            }
        }
    }

    private func detect() {
        var candidate = server
        candidate.username = server.username.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if await client.detect(server: candidate, secret: password), client.installation == .ready {
                ready(false)
            }
        }
    }

    private var installationTitle: String {
        client.installation == .repair ? "Восстановить SFERA?" : "Установить SFERA?"
    }

    private var installSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(installationTitle).font(.title2.weight(.semibold))
            Text(client.installation == .repair
                 ? "На VPS есть файлы SFERA, но служба недоступна."
                 : "На этом VPS SFERA ещё не установлена.")
                .foregroundStyle(Palette.muted)
            if ServerRelease.repository == nil {
                Label("Источник серверных релизов ещё не задан в этой сборке.", systemImage: "info.circle")
                    .foregroundStyle(Palette.muted)
            } else {
                Text("Для Debian 12/13 и Ubuntu 24.04/26.04 нужны TCP 80 и 443, UDP 443 и доступ по SSH.")
                    .font(.callout).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                field("Email для сертификата") {
                    TextField("name@example.com", text: $email).textContentType(.emailAddress)
                }
                Text("Установщик SFERA запустится на VPS с правами root и примет условия Let’s Encrypt.")
                    .font(.caption).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Закрыть", role: .cancel) { showingInstall = false }.keyboardShortcut(.cancelAction)
                Button(client.installation == .repair ? "Восстановить" : "Установить") {
                    showingInstall = false
                    var candidate = server
                    candidate.username = server.username.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        if await client.install(server: candidate, secret: password, email: email) {
                            password = ""
                            ready(true)
                        }
                    }
                }
                .buttonStyle(PrimaryButton())
                .disabled(ServerRelease.repository == nil || email.isEmpty)
            }
        }
        .padding(25)
        .frame(width: 350)
        .presentationBackground(Palette.surface)
    }

    private func field<Control: View>(_ title: String, focused: Bool = false,
                                      @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(Palette.muted)
            control()
                .font(.system(size: 15))
                .textFieldStyle(.plain)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? Palette.accent : Palette.line, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func pickKey() {
        clearResult()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.message = "Выберите приватный SSH-ключ. Ключ с паролем можно заранее добавить в ssh-agent."
        if panel.runModal() == .OK {
            server.identityPath = panel.url?.path
        }
    }
}

private struct ProgressLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(Palette.muted)
        }
    }
}
