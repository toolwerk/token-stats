import AppKit
import SwiftUI
import TokenStatsCore

/// Einstellungsfenster, Abschnitte „Anzeige“, „Verbrauch“, „Aktualisierung“ und „Updates“ (SPEC §4).
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let store: UsageStore
    let consumption: ConsumptionStore
    @Bindable var updater: Updater

    @State private var launchAtLogin = false

    private let intervals: [TimeInterval] = [300, 600, 900, 1800, 3600]

    var body: some View {
        Form {
            Section("Anzeige") {
                Picker("Menüleiste", selection: $settings.menuBarMode) {
                    ForEach(MenuBarMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Angezeigter Wert", selection: $settings.fixedWindow) {
                    Text("Knappstes Limit").tag(String?.none)
                    Divider()
                    ForEach(windowChoices, id: \.key) { choice in
                        Text(choice.label).tag(Optional(choice.key))
                    }
                }

                Toggle("Zustandsfarbe im Icon verwenden", isOn: $settings.useStateColor)
                Toggle("API-Vergleichswert in Geld anzeigen", isOn: $settings.showMoney)
                Toggle("Bei Anmeldung starten", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        settings.launchAtLogin = newValue
                        launchAtLogin = settings.launchAtLogin
                    }
            }

            AccountsSection(settings: settings, store: store) {
                store.reloadAccounts()
                store.refresh(manual: false)
                consumption.refresh()
            }

            Section {
                Picker("Stichtag des Abos", selection: $settings.billingDay) {
                    ForEach(1...31, id: \.self) { Text("\($0).").tag($0) }
                }
                .onChange(of: settings.billingDay) { consumption.refresh() }
            } header: {
                Text("Verbrauch")
            } footer: {
                Text("Beginn des Zeitraums „Abrechnungsmonat“. In kürzeren Monaten gilt der Monatsletzte.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Abfrageintervall", selection: $settings.refreshInterval) {
                    ForEach(intervals, id: \.self) { Text("\(Int($0 / 60)) Min.").tag($0) }
                }
            } header: {
                Text("Aktualisierung")
            } footer: {
                Text("Die Usage-Endpunkte sind hart rate-limitiert. Kürzer als 5 Minuten führt zu Fehlern.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Stand nach iCloud übertragen", isOn: $settings.cloudSync)
            } header: {
                Text("iPhone")
            } footer: {
                Text(cloudFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!SnapshotCloud.isEntitled)

            Section {
                Toggle("Automatisch nach Updates suchen", isOn: $updater.automaticallyChecks)
                LabeledContent("Version \(Self.version)") {
                    Button("Jetzt suchen") { updater.checkNow() }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(updatesFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!updater.isAvailable)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchAtLogin = settings.launchAtLogin }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var cloudFooter: String {
        guard SnapshotCloud.isEntitled else { return "In diesem Build nicht enthalten (keine iCloud-Berechtigung)." }
        return "Limits und Verbrauch dieses Macs – Prozente, Reset-Zeiten, Tagessummen – in deine private iCloud-Datenbank, für die Token-Stats-App auf dem iPhone. Keine Zugangsdaten, keine Logs."
    }

    private var updatesFooter: String {
        guard updater.isAvailable else { return "In Debug-Builds abgeschaltet." }
        let last = updater.lastCheck.map { "Zuletzt gesucht \(Format.ago($0))." } ?? "Noch nicht gesucht."
        return "Einmal täglich, ohne Systemdaten. Updates werden beim Beenden installiert. \(last)"
    }

    /// Alle bekannten Limits als „Claude · Woche“ bzw. „Claude · frank · Woche“.
    private var windowChoices: [(key: String, label: String)] {
        store.sortedProviders.flatMap { provider in
            (store.states[provider.id]?.snapshot?.windows ?? []).map {
                (key: "\(provider.id)/\($0.id)", label: "\(store.title(for: provider)) · \($0.name)")
            }
        }
    }
}

/// Abschnitt „Konten“ (SPEC §6 „Mehrere Konten je Anbieter“): erkannte Konten je Anbieter
/// mit Bezeichnung und Schalter, dazu Ordner von Hand hinzufügen.
private struct AccountsSection: View {
    @Bindable var settings: AppSettings
    let store: UsageStore
    /// Nach jeder Änderung: Konten neu suchen, Verbrauch neu einlesen.
    let changed: () -> Void

    var body: some View {
        Section {
            ForEach(store.providers.filter { $0.isInstalled() }, id: \.id) { provider in
                row(provider)
            }
            HStack {
                Spacer()
                ForEach(AccountDiscovery.FolderKind.allCases, id: \.self) { kind in
                    Button("\(kind.displayName)-Ordner hinzufügen …") { addFolder(kind) }
                }
            }
        } header: {
            Text("Konten")
        } footer: {
            Text("Weitere Konten legt die CLI mit eigenem Ordner an: »CLAUDE_CONFIG_DIR=~/.claude-2 claude« bzw. »CODEX_HOME=~/.codex-2 codex«. Ordner wie ~/.claude-2 im Home werden automatisch gefunden. Ausgeblendete Konten werden nicht abgefragt.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ provider: any UsageProvider) -> some View {
        let hidden = settings.hiddenAccounts.contains(provider.id)
        let email = provider.source.email ?? store.states[provider.id]?.snapshot?.account?.name
        let origin = provider.source.folderDisplay ?? (provider.isDefaultAccount ? "Standard" : nil)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { !settings.hiddenAccounts.contains(provider.id) },
                set: { show in
                    if show { settings.hiddenAccounts.remove(provider.id) } else { settings.hiddenAccounts.insert(provider.id) }
                    changed()
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help("Anzeigen")
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName + (email.map { " · \($0)" } ?? ""))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let origin {
                    Text(origin).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .foregroundStyle(hidden ? .secondary : .primary)
            Spacer(minLength: 8)
            TextField("Bezeichnung", text: Binding(
                get: { settings.accountLabels[provider.id] ?? "" },
                set: { settings.accountLabels[provider.id] = $0.isEmpty ? nil : $0 }
            ), prompt: Text(provider.source.automaticLabel ?? "Bezeichnung"))
            .labelsHidden()
            .frame(width: 110)
            if provider.source.origin == .manual, let path = provider.source.folder?.path {
                Button {
                    removeFolder(path, kind: provider.kind)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Ordner entfernen")
            }
        }
    }

    private func addFolder(_ kind: AccountDiscovery.FolderKind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.message = "Ordner, den \(kind.variable) für das weitere Konto nennt"
        panel.prompt = "Hinzufügen"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var folders = settings.accountFolders[kind.rawValue] ?? []
        if !folders.contains(url.path) { folders.append(url.path) }
        settings.accountFolders[kind.rawValue] = folders
        changed()
    }

    private func removeFolder(_ path: String, kind: String) {
        settings.accountFolders[kind]?.removeAll { URL(filePath: $0).standardizedFileURL.path == path }
        if settings.accountFolders[kind]?.isEmpty == true { settings.accountFolders[kind] = nil }
        changed()
    }
}
