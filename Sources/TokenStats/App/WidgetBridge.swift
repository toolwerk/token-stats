import Foundation
import Observation
import TokenStatsCore
import WidgetKit

/// Gibt den Widgets den Stand (Issue #10): schreibt `widgets.json` in die App Group, sobald
/// sich Limits, Verbrauch oder die Geld-Einstellung ändern, und lädt dann die Timelines neu.
/// Ist „Stand nach iCloud übertragen“ an, geht derselbe Stand im selben Takt an die private
/// CloudKit-Datenbank, für die iOS-App (Issue #11).
///
/// Die Erweiterung liest nur diese Datei – keine Zugangsdaten, kein `usage.sqlite`, keine
/// Endpunkte. Ein neuer Limit-Stand lädt sofort neu; Verbrauchsänderungen allein höchstens
/// alle fünf Minuten, wie der Abfragetakt, damit das Neuladen nicht im Minutentakt läuft.
@MainActor
final class WidgetBridge {
    private let store: UsageStore
    private let consumption: ConsumptionStore
    private let settings: AppSettings

    private var lastWritten: WidgetSnapshot?
    private var lastReload: Date = .distantPast
    private var lastPublished: WidgetSnapshot?
    private var publishing = false
    private var pendingWrite: Task<Void, Never>?
    private var pendingReload: Task<Void, Never>?

    static let usageReloadInterval: TimeInterval = 300

    init(store: UsageStore, consumption: ConsumptionStore, settings: AppSettings) {
        self.store = store
        self.consumption = consumption
        self.settings = settings
    }

    func start() {
        observe()
    }

    /// Baut den Stand neu, sobald sich eine der beobachteten Quellen ändert.
    private func observe() {
        let snapshot = withObservationTracking {
            build()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        schedule(snapshot)
    }

    private func build() -> WidgetSnapshot {
        let providers = store.sortedProviders.map { provider -> WidgetSnapshot.Provider in
            let state = store.states[provider.id]
            return WidgetSnapshot.Provider(
                id: provider.id,
                name: store.title(for: provider),
                snapshot: state?.snapshot,
                isRateLimited: state?.isRateLimited ?? false,
                message: store.problem(for: provider) ?? state?.error ?? state?.note,
                kind: provider.kind,
                kindName: provider.displayName
            )
        }
        let usage = ConsumptionStore.providers.flatMap { provider in
            UsagePeriod.allCases.compactMap { period in
                consumption.summary(provider, period).map { WidgetSnapshot.Usage(provider: provider, period: period, summary: $0) }
            }
        }
        // cloudSync wird hier gelesen, damit ein Umschalten den Stand sofort überträgt.
        return WidgetSnapshot(machine: settings.cloudSync ? Host.current().localizedName : nil,
                              showMoney: settings.showMoney, providers: providers, usage: usage,
                              accountNames: accountNames())
    }

    /// Letzte bekannte Titel aller Konten, auch ausgeblendeter und entfernter: Die Widget-Auswahl
    /// nennt ein verschwundenes Konto damit beim Namen („Claude · Kunde A“, „nicht mehr da“)
    /// statt mit `claude@…`. Nur Titel, keine Pfade oder Adressen. Begrenzt über
    /// `KnownAccountNames.merge`.
    private func accountNames() -> [String: String] {
        let known = store.providers
        var current: [String: String] = [:]
        for provider in known {
            let several = known.filter { $0.kind == provider.kind }.count > 1
            current[provider.id] = several
                ? store.label(for: provider).map { "\(provider.displayName) · \($0)" } ?? provider.displayName
                : provider.displayName
        }
        pendingNames = KnownAccountNames.merge(stored: storedNames, current: current, now: .now)
        return pendingNames.mapValues(\.name)
    }

    /// Gemerkte Titel mit letztem Sichtdatum, aus den UserDefaults. Die frühere Fassung
    /// (`widgetAccountNames`, nur ID → Titel) wird einmal übernommen, mit „jetzt“ als letztem
    /// Sichtdatum; der alte Schlüssel entfällt nach dem nächsten Schreiben.
    private var storedNames: [String: KnownAccountNames.Entry] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.accountNamesKey) {
            return (try? JSONDecoder().decode([String: KnownAccountNames.Entry].self, from: data)) ?? [:]
        }
        let legacy = defaults.dictionary(forKey: Self.legacyAccountNamesKey) as? [String: String] ?? [:]
        return KnownAccountNames.migrate(legacy: legacy, now: .now)
    }

    private var pendingNames: [String: KnownAccountNames.Entry] = [:]

    private static let accountNamesKey = "widgetAccountNamesV2"
    private static let legacyAccountNamesKey = "widgetAccountNames"

    /// Kurz sammeln: Mehrere Anbieter antworten oft innerhalb weniger Sekunden.
    private func schedule(_ snapshot: WidgetSnapshot) {
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.write(snapshot)
        }
    }

    private func write(_ snapshot: WidgetSnapshot) {
        if let last = lastWritten, last.providers == snapshot.providers, last.usage == snapshot.usage,
           last.showMoney == snapshot.showMoney, last.machine == snapshot.machine, last.accountNames == snapshot.accountNames {
            return
        }
        do {
            try snapshot.write()
            if !store.isDemo, let data = try? JSONEncoder().encode(pendingNames) {
                UserDefaults.standard.set(data, forKey: Self.accountNamesKey)
                UserDefaults.standard.removeObject(forKey: Self.legacyAccountNamesKey)
            }
            #if DEBUG
            NSLog("Token Stats: Widget-Stand geschrieben (%d Anbieter, %d Verbrauchszeilen)", snapshot.providers.count, snapshot.usage.count)
            #endif
        } catch {
            NSLog("Token Stats: Widget-Stand nicht schreibbar: \(error.localizedDescription)")
            return
        }
        let limitsChanged = lastWritten.map { $0.providers != snapshot.providers || $0.showMoney != snapshot.showMoney } ?? true
        lastWritten = snapshot
        let due = lastReload.addingTimeInterval(Self.usageReloadInterval)
        if limitsChanged || due <= .now {
            reload()
        } else if pendingReload == nil {
            pendingReload = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(due.timeIntervalSinceNow, 1)))
                guard !Task.isCancelled else { return }
                self?.pendingReload = nil
                self?.reload()
            }
        }
    }

    private func reload() {
        pendingReload?.cancel()
        pendingReload = nil
        lastReload = .now
        WidgetCenter.shared.reloadAllTimelines()
        publish()
    }

    /// Denselben Stand nach iCloud – nur mit Einstellung und Berechtigung, nie doppelt.
    private func publish() {
        guard settings.cloudSync, SnapshotCloud.isEntitled, let snapshot = lastWritten,
              snapshot.machine != nil, snapshot != lastPublished, !publishing else { return }
        publishing = true
        let machineID = settings.machineID
        Task {
            do {
                try await SnapshotCloud.publish(snapshot, machineID: machineID)
                lastPublished = snapshot
            } catch {
                NSLog("Token Stats: iCloud-Übertragung fehlgeschlagen: \(error.localizedDescription)")
            }
            publishing = false
        }
    }
}

/// Gemerkte Kontotitel für die Widget-Auswahl (SPEC §6 „Widgets“). Damit die Liste nicht ohne
/// Ende wächst: Titel aktueller Konten bleiben immer; ein verschwundenes Konto behält seinen
/// Titel 180 Tage ab dem letzten Sehen, höchstens 50 davon (die zuletzt gesehenen). Ein Widget,
/// das danach noch auf das Konto zeigt, nennt es „Claude · Konto“ mit „nicht mehr da“ – nie
/// die rohe Kennung.
enum KnownAccountNames {
    struct Entry: Codable, Equatable {
        var name: String
        var lastSeen: Date
    }

    static let keepFor: TimeInterval = 180 * 24 * 3600
    static let maxVanished = 50

    /// Alte Fassung ohne Sichtdatum: alle Titel übernehmen, zuletzt gesehen „jetzt“.
    static func migrate(legacy: [String: String], now: Date) -> [String: Entry] {
        legacy.mapValues { Entry(name: $0, lastSeen: now) }
    }

    static func merge(stored: [String: Entry], current: [String: String], now: Date) -> [String: Entry] {
        var result = current.mapValues { Entry(name: $0, lastSeen: now) }
        let vanished = stored
            .filter { current[$0.key] == nil && now.timeIntervalSince($0.value.lastSeen) <= keepFor }
            .sorted { $0.value.lastSeen != $1.value.lastSeen ? $0.value.lastSeen > $1.value.lastSeen : $0.key < $1.key }
            .prefix(maxVanished)
        for (id, entry) in vanished { result[id] = entry }
        return result
    }
}
