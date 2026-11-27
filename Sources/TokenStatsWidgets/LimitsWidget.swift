import AppIntents
import SwiftUI
import TokenStatsCore
import WidgetKit

// MARK: Konfiguration

/// Konto für das Widget „Limits“, dynamisch aus dem Widget-Stand: „Knappstes Limit“ und je
/// Konto ein Eintrag („Claude · frank“). Die IDs der Standardkonten (`claude`) sind dieselben
/// wie die des früheren Anbieter-Enums (SPEC §6 „Mehrere Konten“).
struct LimitsAccountEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Konto"
    static let defaultQuery = LimitsAccountQuery()
    static let tightest = LimitsAccountEntity(id: "tightest", name: "Knappstes Limit")

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    /// `nil` = knappstes Limit über alle Konten.
    var providerID: String? { id == Self.tightest.id ? nil : id }
}

struct LimitsAccountQuery: EntityQuery {
    /// Ohne Widget-Stand (ad hoc signierter Build): die bekannten Anbieter.
    private static let fallback = [("antigravity", "Antigravity"), ("claude", "Claude"), ("codex", "Codex"), ("ollama", "Ollama")]

    func entities(for identifiers: [String]) async throws -> [LimitsAccountEntity] {
        let all = Self.all()
        // Unbekannte IDs behalten (Konto gerade ausgeblendet): Die Auswahl soll nicht verloren gehen.
        return identifiers.map { id in all.first { $0.id == id } ?? LimitsAccountEntity(id: id, name: id) }
    }

    func suggestedEntities() async throws -> [LimitsAccountEntity] { Self.all() }

    func defaultResult() async -> LimitsAccountEntity? { .tightest }

    private static func all() -> [LimitsAccountEntity] {
        let accounts = WidgetSnapshot.loadForWidgets()?.providers.map { LimitsAccountEntity(id: $0.id, name: $0.name) }
        return [.tightest] + ((accounts?.isEmpty == false ? accounts : nil) ?? fallback.map { LimitsAccountEntity(id: $0.0, name: $0.1) })
    }
}

struct LimitsConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Limits"
    static let description = IntentDescription("Session- und Wochenlimit mit Pace-Marke aus Token Stats.")

    @Parameter(title: "Konto")
    var provider: LimitsAccountEntity?
}

// MARK: Timeline

struct LimitsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let provider: String?
}

struct LimitsTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LimitsEntry {
        LimitsEntry(date: .now, snapshot: DemoData.widgetSnapshot(now: .now), provider: nil)
    }

    func snapshot(for configuration: LimitsConfigurationIntent, in context: Context) async -> LimitsEntry {
        let snapshot = context.isPreview ? DemoData.widgetSnapshot(now: .now) : WidgetSnapshot.loadForWidgets()
        return LimitsEntry(date: .now, snapshot: snapshot, provider: configuration.provider?.providerID)
    }

    func timeline(for configuration: LimitsConfigurationIntent, in context: Context) async -> Timeline<LimitsEntry> {
        let entry = LimitsEntry(date: .now, snapshot: WidgetSnapshot.loadForWidgets(), provider: configuration.provider?.providerID)
        return Timeline(entries: [entry], policy: .never)
    }
}

// MARK: Widget

struct LimitsWidget: Widget {
    static let kind = "de.mahype.TokenStats.limits"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: LimitsConfigurationIntent.self, provider: LimitsTimelineProvider()) { entry in
            LimitsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Limits")
        .description("Die Meter eines Anbieters mit Reset-Zeit und Pace-Marke – wie im Popover.")
        .supportedFamilies(WidgetFamily.limitsFamilies)
    }
}

struct LimitsWidgetEntryView: View {
    let entry: LimitsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let shown = entry.snapshot.flatMap { LimitsWidgetView.resolve($0, provider: entry.provider) }?.id
        Group {
            #if os(iOS)
            if family.isAccessory {
                LockScreenLimitsView(entry: entry)
            } else {
                LimitsWidgetView(snapshot: entry.snapshot, provider: entry.provider, size: family.size, now: entry.date)
            }
            #else
            LimitsWidgetView(snapshot: entry.snapshot, provider: entry.provider, size: family.size, now: entry.date)
            #endif
        }
        .widgetURL(WidgetLink.url(.init(page: .limits, provider: family.size == .large ? nil : shown)))
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
