import Foundation

// Wann die Widgets neu laden und welche Einträge eine Timeline trägt – als reine Funktionen,
// damit sie ohne WidgetKit testbar sind (SPEC §7 „Widgets“).

// MARK: - Neuladen aus der App

/// Entscheidet, ob die App nach dem Schreiben von `widgets.json` `reloadAllTimelines()`
/// anstößt. Das Budget von WidgetKit ist knapp; ein Abruf ohne neuen Inhalt – nur ein neuer
/// `fetchedAt` – darf darum nicht neu laden.
public enum WidgetReload {
    /// Verbrauchsänderungen allein höchstens so oft, wie der Abfragetakt (SPEC §2).
    public static let usageInterval: TimeInterval = 300

    /// Abweichung der Reset-Zeit, die noch als derselbe Reset gilt. Manche Anbieter liefern
    /// den Zeitpunkt mit wechselnden Sekundenbruchteilen; angezeigt wird höchstens die Minute.
    public static let resetTolerance: TimeInterval = 60

    public enum Decision: Equatable, Sendable {
        /// Nichts Sichtbares geändert – nicht neu laden.
        case skip
        /// Sofort neu laden.
        case now
        /// Nur der Verbrauch hat sich geändert – neu laden, sobald der Takt es erlaubt.
        case at(Date)
    }

    /// - Parameters:
    ///   - shown: der Stand, mit dem zuletzt neu geladen wurde (`nil` = noch nie).
    ///   - current: der gerade geschriebene Stand.
    ///   - lastReload: Zeitpunkt des letzten Neuladens.
    public static func decide(shown: WidgetSnapshot?, current: WidgetSnapshot, lastReload: Date,
                              now: Date, usageInterval: TimeInterval = usageInterval) -> Decision {
        guard let shown else { return .now }
        if limitsChanged(from: shown, to: current) { return .now }
        guard shown.usage != current.usage else { return .skip }
        let due = lastReload.addingTimeInterval(usageInterval)
        return due <= now ? .now : .at(due)
    }

    /// Inhaltliche Änderung an Limits oder Anzeige: Fenster, Prozente, Reset-Zeiten, Konto,
    /// Extras, Fehler/Hinweis, Rate-Limit, Geld-Einstellung, Mac-Name. Reine Abrufzeitpunkte
    /// (`ProviderSnapshot.fetchedAt`, `WidgetSnapshot.writtenAt`) zählen nicht.
    public static func limitsChanged(from old: WidgetSnapshot, to new: WidgetSnapshot) -> Bool {
        if old.showMoney != new.showMoney || old.machine != new.machine { return true }
        guard old.providers.count == new.providers.count else { return true }
        return zip(old.providers, new.providers).contains { !sameContent($0, $1) }
    }

    static func sameContent(_ a: WidgetSnapshot.Provider, _ b: WidgetSnapshot.Provider) -> Bool {
        guard a.id == b.id, a.name == b.name, a.isRateLimited == b.isRateLimited, a.message == b.message else { return false }
        switch (a.snapshot, b.snapshot) {
        case (nil, nil): return true
        case let (x?, y?): return sameContent(x, y)
        default: return false
        }
    }

    static func sameContent(_ a: ProviderSnapshot, _ b: ProviderSnapshot) -> Bool {
        guard a.account == b.account, a.extras == b.extras, a.windows.count == b.windows.count else { return false }
        return zip(a.windows, b.windows).allSatisfy(sameContent)
    }

    static func sameContent(_ a: LimitWindow, _ b: LimitWindow) -> Bool {
        guard a.id == b.id, a.name == b.name, a.scopeNote == b.scopeNote, a.percent == b.percent,
              a.windowLength == b.windowLength else { return false }
        switch (a.resetsAt, b.resetsAt) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x.timeIntervalSince(y)) < resetTolerance
        default: return false
        }
    }
}

// MARK: - Timeline der Erweiterung

/// Einträge einer Widget-Timeline: jetzt, dann im 15-Minuten-Raster für einige Stunden, dazu
/// die Reset-Zeiten der Limit-Fenster und das Tagesende („Heute“). So rücken Pace-Marke,
/// „Reset in …“ und der Tageswechsel weiter, auch wenn die App gerade nichts Neues schreibt.
/// Nach dem letzten Eintrag holt WidgetKit eine neue Timeline (`.after`).
public enum WidgetTimeline {
    public static let step: TimeInterval = 15 * 60
    public static let horizon: TimeInterval = 6 * 3600

    public struct Plan: Equatable, Sendable {
        /// Aufsteigend, ohne Doppelte, der erste ist `now`.
        public var dates: [Date]
        /// Zeitpunkt für `TimelineReloadPolicy.after` – der letzte Eintrag.
        public var reloadAfter: Date
    }

    public static func plan(now: Date, snapshot: WidgetSnapshot?, calendar: Calendar = .current,
                            step: TimeInterval = step, horizon: TimeInterval = horizon) -> Plan {
        let end = now.addingTimeInterval(horizon)
        var dates: [Date] = []

        // Raster auf volle Viertelstunden (alle Zeitzonen liegen auf Vielfachen von 15 Min.).
        var next = (now.timeIntervalSinceReferenceDate / step).rounded(.down) * step + step
        while next <= end.timeIntervalSinceReferenceDate {
            dates.append(Date(timeIntervalSinceReferenceDate: next))
            next += step
        }

        // Lokale Mitternacht(en) im Horizont.
        var midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        while let day = midnight, day <= end {
            dates.append(day)
            midnight = calendar.date(byAdding: .day, value: 1, to: day)
        }

        if let snapshot {
            // Resets: auf die volle Sekunde aufgerundet, damit der Eintrag sicher danach liegt.
            for provider in snapshot.providers {
                for window in provider.snapshot?.windows ?? [] {
                    if let reset = window.resetsAt { dates.append(Date(timeIntervalSinceReferenceDate: reset.timeIntervalSinceReferenceDate.rounded(.up))) }
                }
            }
            // Ende des Tages, den „Heute“ abdeckt – auf dem iPhone ist das der Tag des Macs.
            for usage in snapshot.usage where usage.period == .today {
                if let end = usage.summary.days.last.flatMap({ calendar.date(byAdding: .day, value: 1, to: $0.day) }) {
                    dates.append(end)
                }
            }
        }

        let sorted = Set(dates.filter { $0 > now && $0 <= end }).sorted()
        return Plan(dates: [now] + sorted, reloadAfter: sorted.last ?? end)
    }
}

// MARK: - Stand zu einem Zeitpunkt

extension WidgetSnapshot {
    /// Der Stand, wie ihn ein Widget-Eintrag zum Zeitpunkt `now` zeigt: Fenster mit
    /// vergangenem Reset stehen auf 0 % (wie in der App), und „Heute“ fällt weg, sobald der
    /// Tag des Stands vorbei ist – dann zeigt das Widget „Keine Einträge“ statt der Zahlen
    /// von gestern, bis die App neu schreibt.
    public func current(at now: Date, calendar: Calendar = .current) -> WidgetSnapshot {
        var result = self
        result.providers = providers.map { provider in
            guard var snapshot = provider.snapshot else { return provider }
            snapshot.windows = snapshot.windows.map { $0.rolledOver(now: now) }
            var provider = provider
            provider.snapshot = snapshot
            return provider
        }
        result.usage.removeAll { usage in
            guard usage.period == .today, let day = usage.summary.days.last?.day,
                  let end = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
            return now >= end
        }
        return result
    }
}
