import SwiftUI

struct DirectSitesEditor: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("directSites.useRussianSites") private var useRussianSites = false
    @AppStorage("directSites.custom") private var custom = ""
    @State private var draft = DirectSites()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Сайты без VPN").font(.title2.bold())
            Toggle("Популярные сайты России", isOn: $draft.useRussianSites)
            Text("Яндекс, VK, Госуслуги, банки и маркетплейсы.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Свои сайты").font(.headline)
            Text("Вставьте домены или ссылки, по одному на строку.")
                .font(.footnote).foregroundStyle(.secondary)
            TextEditor(text: $draft.custom)
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel("Свои сайты без VPN")
                .frame(minHeight: 120, maxHeight: 160)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.35)))
            Text("Исключения действуют на IPv4-адреса, найденные при подключении. Сайты с общим IP тоже могут пойти напрямую. Поддомены добавляются отдельно.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить", action: save).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(idealWidth: 460)
        .onAppear { draft = DirectSites(useRussianSites: useRussianSites, custom: custom) }
    }

    private func save() {
        do {
            _ = try draft.hosts()
            useRussianSites = draft.useRussianSites
            custom = draft.custom
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
