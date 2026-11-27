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
        // So hoch wie der Inhalt, höchstens so hoch wie der Bildschirm – bei vielen Konten
        // scrollt das Formular mit normaler Scrollleiste (Entwurf „Viele Konten“).
        .frame(maxHeight: Self.maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchAtLogin = settings.launchAtLogin }
    }

    private static var maxHeight: CGFloat {
        max((NSScreen.main?.visibleFrame.height ?? 800) - 80, 400)
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

/// Abschnitt „Konten“ (SPEC §6 „Mehrere Konten je Anbieter“), nach Designer-Entwurf und
/// Feldplan vom 27.11.2026: Gruppen je Anbieter, beschriftete Checkbox, Herkunft, E-Mail und
/// Ordner ungekürzt, Umbenennen per Stift, Fehler als Satz in der Zeile. Wirkt sofort.
private struct AccountsSection: View {
    @Bindable var settings: AppSettings
    let store: UsageStore
    /// Nach jeder Änderung: Konten neu suchen, Verbrauch neu einlesen.
    let changed: () -> Void

    /// Konto, dessen Bezeichnung gerade bearbeitet wird.
    @State private var editing: String?
    @State private var draft = ""

    var body: some View {
        Section {
            let claude = entries(.claude)
            let codex = entries(.codex)
            if claude.isEmpty && codex.isEmpty {
                emptyState
            } else {
                group(.claude, claude)
                group(.codex, codex)
            }
            let others = store.entries.filter { AccountDiscovery.FolderKind(rawValue: $0.provider.kind) == nil && $0.provider.isInstalled() }
            if !others.isEmpty {
                groupTitle("Weitere Anbieter")
                ForEach(others, id: \.id) { otherRow($0.provider) }
            }
        } header: {
            Text("Konten")
                #if DEBUG
                .onAppear {
                    // Für Bilder des offenen Feldes: TOKENSTATS_DEMO_EDIT=<Konto-ID>, nur mit Demo-Konten.
                    if store.isDemo, let id = ProcessInfo.processInfo.environment["TOKENSTATS_DEMO_EDIT"],
                       let provider = store.provider(id: id) {
                        draft = ProcessInfo.processInfo.environment["TOKENSTATS_DEMO_EDIT_TEXT"] ?? store.customLabel(provider.id) ?? ""
                        editing = provider.id
                    }
                }
                #endif
        } footer: {
            // Befehle als eigene Mono-Zeilen, nie im Wort getrennt; Text(verbatim:) innen, damit
            // SwiftUI „~/.claude-2 … ~/.codex-2“ nicht als Markdown-Durchstreichung liest.
            CommandText("Weitere Konten legst du mit eigenem Ordner an: »CLAUDE_CONFIG_DIR=~/.claude-2 claude« bzw. »CODEX_HOME=~/.codex-2 codex«. Ordner wie ~/.claude-2 findet Token Stats selbst. Ausgeblendete Konten werden nicht abgefragt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Einträge eines Anbieters: das Standardkonto nur, wenn es da ist; Ordner „von Hand“
    /// immer, auch wenn sie fehlen oder doppelt sind – sonst ließen sie sich nicht entfernen.
    private func entries(_ kind: AccountDiscovery.FolderKind) -> [AccountEntry] {
        store.entries.filter { entry in
            guard entry.provider.kind == kind.rawValue else { return false }
            return entry.status != .ok || entry.provider.isInstalled()
        }
    }

    // MARK: Gruppen

    @ViewBuilder
    private func group(_ kind: AccountDiscovery.FolderKind, _ entries: [AccountEntry]) -> some View {
        groupTitle(kind.displayName)
        ForEach(entries.filter { !$0.isDuplicate }, id: \.id) { accountRow($0, kind: kind) }
        ForEach(entries.filter(\.isDuplicate), id: \.id) { duplicateRow($0) }
        HStack {
            Spacer()
            addButton(kind)
        }
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Noch kein Konto gefunden").font(.headline)
            Text("Melde dich in Claude Code oder Codex an. Liegt eine Anmeldung in einem anderen Ordner, füge ihn hier hinzu.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                addButton(.claude)
                addButton(.codex)
            }
            .padding(.top, 4)
        }
    }

    private func addButton(_ kind: AccountDiscovery.FolderKind) -> some View {
        Button("\(kind.displayName)-Ordner hinzufügen …") { addFolder(kind) }
    }

    // MARK: Zeilen

    /// Kontozeile. Kopf mit Checkbox, Abzeichen und Knöpfen; Editor, Angaben und Hinweisflächen
    /// darunter über die volle Zeilenbreite, damit alle Flächen an derselben Kante enden.
    private func accountRow(_ entry: AccountEntry, kind: AccountDiscovery.FolderKind) -> some View {
        let provider = entry.provider
        let missing = entry.status == .missingFolder
        return VStack(alignment: .leading, spacing: 4) {
            if editing == provider.id {
                editor(provider)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if missing {
                            // Deaktivierte Checkbox ohne Haken; der Name daneben bleibt in Primärfarbe
                            // lesbar (ausgegraut hätte er nur etwa 2:1 Kontrast).
                            Toggle("Anzeigen", isOn: visibility(provider))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .disabled(true)
                                .accessibilityLabel(Text(store.label(for: provider) ?? provider.displayName))
                            Text(store.label(for: provider) ?? provider.displayName)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Toggle(isOn: visibility(provider)) {
                                Text(store.label(for: provider) ?? provider.displayName)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .toggleStyle(.checkbox)
                            .help("Anzeigen")
                        }
                        badge(provider.source.origin.badge)
                    }
                    Spacer(minLength: 8)
                    rowButtons(provider, showPencil: !missing)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                if let email = provider.source.email ?? store.states[provider.id]?.snapshot?.account?.name {
                    Text(email)
                }
                Text(folderText(provider, kind: kind)).font(.system(size: 11, design: .monospaced))
                if store.isHidden(provider.id) {
                    Text("Ausgeblendet, wird nicht abgefragt.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.leading, 20)
            switch entry.status {
            case .missingFolder:
                notice("exclamationmark.triangle", UsageStore.missingFolderHint(hidden: store.isHidden(provider.id)),
                       Severity.crit.textColor, tint: Severity.crit.color)
                    .padding(.leading, 20)
            case .notSignedIn:
                notice("exclamationmark.triangle", "Keine Anmeldung in diesem Ordner. Im Terminal »\(kind.signInCommand(folder: folderText(provider, kind: kind)))« starten.", Severity.warn.textColor, tint: Severity.warn.color)
                    .padding(.leading, 20)
            default:
                EmptyView()
            }
        }
    }

    /// Feste Reihenfolge in jeder Zeile: „Entfernen“ (nur Ordner „von Hand“), ganz rechts der
    /// Stift. Fehlt der Stift (Ordner fehlt), hält ein unsichtbarer Platzhalter die Stelle.
    @ViewBuilder
    private func rowButtons(_ provider: any UsageProvider, showPencil: Bool) -> some View {
        if provider.source.origin == .manual, let path = provider.source.folder?.path {
            Button("Entfernen") { removeFolder(path, kind: provider.kind) }
        }
        Button {
            draft = store.customLabel(provider.id) ?? ""
            editing = provider.id
        } label: {
            Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .help("Bezeichnung ändern")
        .accessibilityLabel("Bezeichnung ändern")
        .opacity(showPencil ? 1 : 0)
        .disabled(!showPencil)
        .accessibilityHidden(!showPencil)
    }

    /// Feld mit Rand über die volle Zeilenbreite, „Fertig“ an der rechten Kante; Enter
    /// übernimmt, Esc bricht ab.
    private func editor(_ provider: any UsageProvider) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Bezeichnung", text: $draft, prompt: Text(provider.source.automaticLabel ?? "Bezeichnung"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .onSubmit { commit(provider) }
                    .onExitCommand { editing = nil }
                    .onChange(of: draft) {
                        if draft.count > AccountSource.maxLabelLength { draft = String(draft.prefix(AccountSource.maxLabelLength)) }
                    }
                Button("Fertig") { commit(provider) }
            }
            Text(editorHint(provider))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func editorHint(_ provider: any UsageProvider) -> String {
        var hint = "Höchstens \(AccountSource.maxLabelLength) Zeichen."
        if let automatic = provider.source.automaticLabel, let source = provider.source.automaticLabelSource {
            hint = "Leer lassen für „\(automatic)“ (\(source)). " + hint
        }
        if draft.split(separator: " ").contains(where: { $0.count > 14 }) {
            hint += " Lange Wörter mit Leerzeichen oder Bindestrich trennen, dann bleibt die Bezeichnung im kleinen Widget lesbar."
        }
        return hint
    }

    private func commit(_ provider: any UsageProvider) {
        store.setLabel(provider.id, draft)
        editing = nil
    }

    /// „~/.claude-kopie gehört zum selben Konto wie „Privat“ …“ – bei Ordnern „von Hand“ entfernbar.
    private func duplicateRow(_ entry: AccountEntry) -> some View {
        let provider = entry.provider
        let kind = AccountDiscovery.FolderKind(rawValue: provider.kind) ?? .claude
        var owner = provider.displayName
        if case .duplicate(let id) = entry.status, let first = store.provider(id: id) {
            owner = store.label(for: first) ?? first.displayName
        }
        return VStack(alignment: .leading, spacing: 4) {
            notice("info.circle", "\(folderText(provider, kind: kind)) gehört zum selben Konto wie „\(owner)“ und wird nicht doppelt gezeigt.", .secondary)
            // „Entfernen“ in derselben Spalte wie in den Kontozeilen, die Fläche darüber volle Breite.
            if provider.source.origin == .manual, let path = provider.source.folder?.path {
                HStack(spacing: 8) {
                    Spacer()
                    Button("Entfernen") { removeFolder(path, kind: provider.kind) }
                    Image(systemName: "pencil").opacity(0).accessibilityHidden(true)
                }
            }
        }
    }

    /// Antigravity und Ollama: eine Quelle je Rechner.
    private func otherRow(_ provider: any UsageProvider) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(provider.displayName, isOn: visibility(provider))
                .toggleStyle(.checkbox)
                .help("Anzeigen")
            Text("Eine Quelle je Rechner, keine weiteren Konten möglich.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
    }

    // MARK: Bausteine

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
            .fixedSize()
    }

    /// Hinweis in der Zeile: Text und Symbol in `color`, Fläche aus `tint` (Standard: `color`).
    private func notice(_ symbol: String, _ text: String, _ color: Color, tint: Color? = nil) -> some View {
        Label {
            // Volle Breite der Zeile, sonst bestimmt die Befehlszeile die Breite und der Satz
            // bricht nach jedem zweiten Wort um.
            CommandText(text).frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption)
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill((tint ?? color).opacity(0.12)))
    }

    /// Ordner wie angezeigt; beim Standardkonto `~/.claude` bzw. `~/.codex`.
    private func folderText(_ provider: any UsageProvider, kind: AccountDiscovery.FolderKind) -> String {
        provider.source.folderDisplay ?? "~/\(kind.standardFolder)"
    }

    private func visibility(_ provider: any UsageProvider) -> Binding<Bool> {
        Binding(
            get: { store.showsAsChecked(provider) },
            set: { show in
                store.setHidden(provider.id, !show)
                changed()
            }
        )
    }

    // MARK: Ordner

    private func addFolder(_ kind: AccountDiscovery.FolderKind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.message = "Ordner, den \(kind.variable) für das weitere Konto nennt"
        panel.prompt = "Hinzufügen"
        guard panel.runModal() == .OK, let url = panel.url, !store.isDemo else { return }
        // Jeder Ordner erscheint danach als Zeile – auch doppelt oder ohne Anmeldung, mit Satz.
        var folders = settings.accountFolders[kind.rawValue] ?? []
        let path = url.standardizedFileURL.path
        if !folders.contains(where: { URL(filePath: $0).standardizedFileURL.path == path }) { folders.append(path) }
        settings.accountFolders[kind.rawValue] = folders
        changed()
    }

    private func removeFolder(_ path: String, kind: String) {
        guard !store.isDemo else { return }
        settings.accountFolders[kind]?.removeAll { URL(filePath: $0).standardizedFileURL.path == path }
        if settings.accountFolders[kind]?.isEmpty == true { settings.accountFolders[kind] = nil }
        changed()
    }
}
