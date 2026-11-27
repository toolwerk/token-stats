import Foundation
import Observation
import TokenStatsCore

/// Hält den letzten Stand je Anbieter, fragt im Takt ab und respektiert Rate-Limits.
@MainActor @Observable
final class UsageStore {
    struct ProviderState: Codable, Equatable {
        var snapshot: ProviderSnapshot?
        var error: String?
        /// Hinweis ohne Fehlercharakter, z. B. „Stand der letzten Nutzung“.
        var note: String?
        /// Letzte Anfrage, die tatsächlich an den Endpunkt ging – Basis für den Takt.
        var lastAttempt: Date?
        /// Bis hierhin keine Abfrage – aus Retry-After nach HTTP 429.
        var retryAt: Date?

        var isRateLimited: Bool { retryAt.map { $0 > .now } ?? false }
    }

    struct Pick: Equatable {
        var providerID: String
        var providerName: String
        var window: LimitWindow
    }

    /// Alle erkannten Konten mit Zustand, auch ausgeblendete, fehlende und doppelte –
    /// die Einstellungen zeigen sie alle (SPEC §6 „Mehrere Konten“).
    private(set) var entries: [AccountEntry]
    private(set) var states: [String: ProviderState] = [:]
    private(set) var loading: Set<String> = []

    private let settings: AppSettings
    private let discover: (@MainActor () -> [AccountEntry])?
    private var lastDiscovery: Date = .distantPast
    private(set) var isDemo = false
    /// Nur im Demo-Modus: Bezeichnungen und Ausblenden im Speicher, nie in den UserDefaults.
    private var demoLabels: [String: String] = [:]
    private var demoHidden: Set<String> = []
    private var timer: Timer?

    /// Abstand zwischen zwei manuellen Aktualisierungen.
    static let manualFloor: TimeInterval = 60
    /// Konten höchstens so oft neu suchen (Ordnerliste + Kontodateien).
    static let discoveryInterval: TimeInterval = 60

    /// `discover` findet die Konten neu (SPEC §6 „Mehrere Konten“); ohne bleiben sie fest.
    init(entries: [AccountEntry], settings: AppSettings, discover: (@MainActor () -> [AccountEntry])? = nil) {
        self.entries = entries
        self.settings = settings
        self.discover = discover
        states = Self.loadCache()
    }

    convenience init(providers: [any UsageProvider], settings: AppSettings) {
        self.init(entries: providers.map { AccountEntry(provider: $0, status: .ok) }, settings: settings)
    }

    /// Konten ohne doppelte Anmeldungen, auch ausgeblendete und nicht installierte.
    var providers: [any UsageProvider] {
        entries.filter { !$0.isDuplicate }.map(\.provider)
    }

    /// Sucht die Konten neu; ändert `entries` nur, wenn sich wirklich etwas geändert hat.
    func reloadAccounts() {
        guard let discover, !isDemo else { return }
        lastDiscovery = .now
        let found = discover()
        if found.map(\.id) != entries.map(\.id) || found.map(\.provider.source) != entries.map(\.provider.source)
            || found.map(\.status) != entries.map(\.status) {
            entries = found
        }
    }

    func status(of provider: any UsageProvider) -> AccountEntry.Status {
        entries.first { $0.id == provider.id }?.status ?? .ok
    }

    // MARK: Bezeichnung und Ausblenden

    func isHidden(_ id: String) -> Bool {
        isDemo ? demoHidden.contains(id) : settings.hiddenAccounts.contains(id)
    }

    func setHidden(_ id: String, _ hidden: Bool) {
        if isDemo {
            if hidden { demoHidden.insert(id) } else { demoHidden.remove(id) }
        } else {
            if hidden { settings.hiddenAccounts.insert(id) } else { settings.hiddenAccounts.remove(id) }
        }
    }

    /// Eigene Bezeichnung, wie gespeichert.
    func customLabel(_ id: String) -> String? {
        isDemo ? demoLabels[id] : settings.accountLabels[id]
    }

    /// Speichert die Bezeichnung, höchstens 24 Zeichen; leer = automatische Bezeichnung.
    func setLabel(_ id: String, _ text: String) {
        let trimmed = String(text.trimmingCharacters(in: .whitespaces).prefix(AccountSource.maxLabelLength))
        let value: String? = trimmed.isEmpty ? nil : trimmed
        if isDemo { demoLabels[id] = value } else { settings.accountLabels[id] = value }
    }

    // MARK: Sichtbare Konten

    /// Im Popover sichtbar: nicht ausgeblendet, nicht doppelt und entweder installiert oder
    /// mit einem Fehler, den man sehen soll (Ordner fehlt, keine Anmeldung). Ein fehlender
    /// Ordner verschwindet nie still.
    var visibleProviders: [any UsageProvider] {
        entries.filter { entry in
            guard !entry.isDuplicate, !isHidden(entry.id) else { return false }
            return entry.status == .ok ? entry.provider.isInstalled() : true
        }.map(\.provider)
    }

    /// Abgefragt werden nur sichtbare Konten, deren Quelle da ist.
    var installedProviders: [any UsageProvider] {
        visibleProviders.filter { status(of: $0) != .missingFolder && $0.isInstalled() }
    }

    /// Satz, warum ein Konto nicht abgefragt werden kann – für Popover und Widgets.
    func problem(for provider: any UsageProvider) -> String? {
        let folder = provider.source.folderDisplay ?? provider.source.folder?.path ?? ""
        switch status(of: provider) {
        case .missingFolder:
            return "Ordner nicht gefunden: \(folder). Ist das Laufwerk eingehängt, erscheint das Konto von selbst wieder."
        case .notSignedIn where !provider.isInstalled():
            let kind = AccountDiscovery.FolderKind(rawValue: provider.kind) ?? .claude
            return "Keine Anmeldung in diesem Ordner. Im Terminal »\(kind.signInCommand(folder: folder))« starten."
        default:
            return nil
        }
    }

    /// Hinweis in den Einstellungen bei fehlendem Ordner, je nach Zustand (Designer-Prüfung
    /// PR #5, Runden 11 und 12). Gleiche Sätze wie `AccountEntry.MissingFolderHint` unter Windows.
    nonisolated static func missingFolderHint(hidden: Bool) -> String {
        // Ausgeblendet steht schon darüber – „ausgeblendet“ nicht doppelt (Runde 12, c).
        hidden
            ? "Ordner nicht gefunden."
            : "Ordner nicht gefunden. Das Konto steht grau im Menü. Ist das Laufwerk eingehängt, wird es wieder abgefragt."
    }

    /// Haken der Checkbox „Anzeigen“: Fehlt der Ordner, bleibt sie leer (Sven, Antwort zu PR #5),
    /// sonst angehakt, solange das Konto nicht ausgeblendet ist.
    func showsAsChecked(_ provider: any UsageProvider) -> Bool {
        status(of: provider) != .missingFolder && !isHidden(provider.id)
    }

    /// Konto mit Fehler und ohne Stand: grau mit „!“ in der Kontoleiste.
    func hasProblem(_ provider: any UsageProvider) -> Bool {
        if problem(for: provider) != nil { return true }
        let state = states[provider.id]
        return state?.snapshot == nil && state?.error != nil
    }

    /// Alphabetisch nach Anbieter, darin Standardkonto zuerst, dann nach Bezeichnung –
    /// damit die Tabs nicht springen (SPEC §3.2).
    var sortedProviders: [any UsageProvider] {
        visibleProviders.sorted { a, b in
            if a.displayName != b.displayName {
                return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
            if a.isDefaultAccount != b.isDefaultAccount { return a.isDefaultAccount }
            return (label(for: a) ?? "").localizedStandardCompare(label(for: b) ?? "") == .orderedAscending
        }
    }

    /// Sichtbare Konten desselben Anbieters.
    func accounts(ofKind kind: String) -> [any UsageProvider] {
        sortedProviders.filter { $0.kind == kind }
    }

    /// Bezeichnung des Kontos: eigene, sonst automatisch (E-Mail, Name, Ordner).
    func label(for provider: any UsageProvider) -> String? {
        if let own = customLabel(provider.id)?.trimmingCharacters(in: .whitespaces), !own.isEmpty {
            return own
        }
        if let label = provider.source.automaticLabel { return label }
        if let name = states[provider.id]?.snapshot?.account?.name {
            return AccountSource(email: name.contains("@") ? name : nil, name: name).automaticLabel
        }
        return provider.isDefaultAccount ? "Standard" : nil
    }

    /// Bezeichnung nur, wenn der Anbieter mehrere sichtbare Konten hat.
    func accountLabel(for provider: any UsageProvider) -> String? {
        accounts(ofKind: provider.kind).count > 1 ? label(for: provider) : nil
    }

    /// „Claude“ bei einem Konto, „Claude · frank“ bei mehreren.
    func title(for provider: any UsageProvider) -> String {
        accountLabel(for: provider).map { "\(provider.displayName) · \($0)" } ?? provider.displayName
    }

    /// Log-Ordner der sichtbaren Konten, für die Verbrauchsseite.
    var logRoots: UsageLedger.Roots {
        let visible = installedProviders
        let claude = visible.compactMap { ($0 as? ClaudeProvider)?.projectsDirectory }
        let codex = visible.compactMap { ($0 as? CodexProvider)?.homeDirectory }
        return UsageLedger.Roots(claude: claude, codex: codex)
    }

    func provider(id: String) -> (any UsageProvider)? {
        providers.first { $0.id == id }
    }

    /// Wert für Menüleiste und Popover-Kopf – beide zeigen immer denselben.
    var displayed: Pick? {
        if let fixed = settings.fixedWindow, let pick = pick(for: fixed) { return pick }
        return tightest
    }

    var tightest: Pick? {
        installedProviders.compactMap { provider -> Pick? in
            guard let window = states[provider.id]?.snapshot?.tightestWindow else { return nil }
            return Pick(providerID: provider.id, providerName: title(for: provider), window: window)
        }.max { $0.window.percent < $1.window.percent }
    }

    func pick(for key: String) -> Pick? {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let provider = installedProviders.first(where: { $0.id == parts[0] }),
              let window = states[provider.id]?.snapshot?.windows.first(where: { $0.id == parts[1] })
        else { return nil }
        return Pick(providerID: provider.id, providerName: title(for: provider), window: window)
    }

    var lastUpdate: Date? {
        installedProviders.compactMap { states[$0.id]?.snapshot?.fetchedAt }.max()
    }

    // MARK: Abruf

    func start() {
        reloadAccounts()
        refresh(manual: false)
        // Der Timer prüft nur, ob etwas fällig ist; der eigentliche Takt ist refreshInterval.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(manual: false) }
        }
    }

    func refresh(manual: Bool) {
        let now = Date.now
        if manual || now.timeIntervalSince(lastDiscovery) >= Self.discoveryInterval { reloadAccounts() }
        rollOverResets(now: now)
        for provider in installedProviders where !loading.contains(provider.id) {
            let state = states[provider.id] ?? ProviderState()
            if state.isRateLimited { continue }
            let spacing = manual ? Self.manualFloor : settings.refreshInterval
            if let last = state.lastAttempt, now.timeIntervalSince(last) < spacing { continue }
            fetch(provider)
        }
    }

    private func fetch(_ provider: any UsageProvider) {
        loading.insert(provider.id)
        let previousAttempt = states[provider.id]?.lastAttempt
        states[provider.id, default: ProviderState()].lastAttempt = .now
        Task {
            var state = states[provider.id] ?? ProviderState()
            do {
                state.snapshot = try await provider.fetch()
                state.error = nil
                state.note = nil
                state.retryAt = nil
            } catch let error as ProviderError {
                // Letzte Werte bleiben stehen, nie eine leere Anzeige.
                if case .waitingForToken = error {
                    state.note = error.message
                    state.error = nil
                } else {
                    state.error = error.message
                    state.note = nil
                }
                // Ohne Anfrage kein Grund zu warten: Beim nächsten Timer-Tick werden die
                // Zugangsdaten neu gelesen, damit ein von der CLI erneuertes Token sofort greift.
                if error.isLocal { state.lastAttempt = previousAttempt }
                if case .rateLimited(let retryAfter) = error {
                    state.retryAt = .now.addingTimeInterval(retryAfter ?? settings.refreshInterval)
                }
            } catch {
                state.error = error.localizedDescription
            }
            states[provider.id] = state
            loading.remove(provider.id)
            saveCache()
        }
    }

    /// Ein Fenster, dessen Reset vorbei ist, steht ohne neue Abfrage auf 0 %. Wichtig für
    /// Anbieter, die nur selten abgefragt werden können (Antigravity), aber auch bei Rate-Limit.
    private func rollOverResets(now: Date) {
        for (id, state) in states {
            guard var snapshot = state.snapshot else { continue }
            snapshot.windows = snapshot.windows.map { $0.rolledOver(now: now) }
            if snapshot != state.snapshot { states[id]?.snapshot = snapshot }
        }
    }

    #if DEBUG
    /// Nur für `make screenshots` und `TOKENSTATS_DEMO_ACCOUNTS`: fester Stand, ohne Abruf,
    /// ohne Erkennung und ohne den Cache zu überschreiben. Nie echte Konten.
    func showDemo(_ snapshots: [String: ProviderSnapshot], entries demoEntries: [AccountEntry]? = nil,
                  errors: [String: String] = [:], hidden: Set<String> = [], labels: [String: String] = [:],
                  retryAt: [String: Date] = [:]) {
        let standard: [any UsageProvider] = [ClaudeProvider(), CodexProvider(), AntigravityProvider(), OllamaProvider()]
        entries = demoEntries ?? standard.map { AccountEntry(provider: $0, status: .ok) }
        isDemo = true
        demoHidden = hidden
        demoLabels = labels
        states = snapshots.mapValues { ProviderState(snapshot: $0) }
        for (id, error) in errors { states[id, default: ProviderState()].error = error }
        // Rate-Limit für Bilder („Abfrage pausiert …“), ohne Abfrage und ohne Cache
        for (id, date) in retryAt { states[id, default: ProviderState()].retryAt = date }
    }
    #endif

    // MARK: Cache
    // Nur Prozentwerte und Reset-Zeiten – keine Zugangsdaten. Überlebt Neustarts,
    // damit ein Neustart der App keine zusätzliche Abfrage auslöst.

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "TokenStats/state.json")
    }

    private static func loadCache() -> [String: ProviderState] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: ProviderState].self, from: data)) ?? [:]
    }

    private func saveCache() {
        let url = Self.cacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(states) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
