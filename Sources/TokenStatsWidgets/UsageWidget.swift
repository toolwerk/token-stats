import AppIntents
import SwiftUI
import TokenStatsCore
import WidgetKit

// MARK: Konfiguration

enum PeriodOption: String, AppEnum {
    case today, week, month, billing

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Zeitraum")
    static let caseDisplayRepresentations: [PeriodOption: DisplayRepresentation] = [
        .today: "Heute", .week: "7 Tage", .month: "30 Tage", .billing: "Abrechnungsmonat",
    ]

    var period: UsagePeriod { UsagePeriod(rawValue: rawValue) ?? .today }
}

enum UsageProviderOption: String, AppEnum {
    case all, claude, codex

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Anbieter")
    static let caseDisplayRepresentations: [UsageProviderOption: DisplayRepresentation] = [
        .all: "Alle Anbieter", .claude: "Claude", .codex: "Codex",
    ]

    var providerID: String? { self == .all ? nil : rawValue }
}

struct UsageConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Verbrauch"
    static let description = IntentDescription("Tokens und API-Vergleichswert aus Token Stats.")

    @Parameter(title: "Zeitraum", default: .today)
    var period: PeriodOption

    @Parameter(title: "Anbieter", default: .all)
    var provider: UsageProviderOption
}

// MARK: Timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let provider: String?
    let period: UsagePeriod
}

/// Einträge im Viertelstundentakt und zum Tageswechsel (`WidgetTimeline`), danach `.after`:
/// „Heute“ springt um Mitternacht auf den neuen Tag, auch wenn die App gerade nichts schreibt.
/// Neuen Inhalt stößt die App per `reloadAllTimelines()` an.
struct UsageTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, snapshot: DemoData.widgetSnapshot(now: .now), provider: nil, period: .today)
    }

    func snapshot(for configuration: UsageConfigurationIntent, in context: Context) async -> UsageEntry {
        let snapshot = context.isPreview ? DemoData.widgetSnapshot(now: .now) : WidgetSnapshot.loadForWidgets()
        return UsageEntry(date: .now, snapshot: snapshot, provider: configuration.provider.providerID,
                          period: configuration.period.period)
    }

    func timeline(for configuration: UsageConfigurationIntent, in context: Context) async -> Timeline<UsageEntry> {
        #if DEBUG
        WidgetSizeLog.log("usage", family: context.family, size: context.displaySize)
        #endif
        let snapshot = WidgetSnapshot.loadForWidgets()
        let plan = WidgetTimeline.plan(now: .now, snapshot: snapshot)
        let entries = plan.dates.map {
            UsageEntry(date: $0, snapshot: snapshot?.current(at: $0), provider: configuration.provider.providerID,
                       period: configuration.period.period)
        }
        return Timeline(entries: entries, policy: .after(plan.reloadAfter))
    }
}

// MARK: Widget

struct UsageWidget: Widget {
    static let kind = "de.mahype.TokenStats.usage"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: UsageConfigurationIntent.self, provider: UsageTimelineProvider()) { entry in
            UsageWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Verbrauch")
        .description("Tokens und API-Vergleichswert für Heute, 7 Tage, 30 Tage oder den Abrechnungsmonat.")
        .supportedFamilies(WidgetFamily.systemFamilies)
    }
}

struct UsageWidgetEntryView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        UsageWidgetView(snapshot: entry.snapshot, provider: entry.provider, period: entry.period, size: family.size)
            .widgetURL(WidgetLink.url(.init(page: .usage, provider: entry.provider, period: entry.period)))
            .containerBackground(.fill.tertiary, for: .widget)
    }
}
