import AppIntents
import SwiftUI
import TokenStatsCore
import WidgetKit

// MARK: Konfiguration

enum LimitsProviderOption: String, AppEnum {
    case tightest, antigravity, claude, codex, ollama

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Anbieter")
    static let caseDisplayRepresentations: [LimitsProviderOption: DisplayRepresentation] = [
        .tightest: "Knappstes Limit", .antigravity: "Antigravity", .claude: "Claude", .codex: "Codex", .ollama: "Ollama",
    ]

    var providerID: String? { self == .tightest ? nil : rawValue }
}

struct LimitsConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Limits"
    static let description = IntentDescription("Session- und Wochenlimit mit Pace-Marke aus Token Stats.")

    @Parameter(title: "Anbieter", default: .tightest)
    var provider: LimitsProviderOption
}

// MARK: Timeline

/// Einträge im Viertelstundentakt und zu den Resets (`WidgetTimeline`), damit Pace-Marke und
/// „Reset in …“ weiterrücken; neuen Inhalt stößt die App per `reloadAllTimelines()` an.
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
        return LimitsEntry(date: .now, snapshot: snapshot, provider: configuration.provider.providerID)
    }

    func timeline(for configuration: LimitsConfigurationIntent, in context: Context) async -> Timeline<LimitsEntry> {
        #if DEBUG
        WidgetSizeLog.log("limits", family: context.family, size: context.displaySize)
        #endif
        let snapshot = WidgetSnapshot.loadForWidgets()
        let plan = WidgetTimeline.plan(now: .now, snapshot: snapshot)
        let entries = plan.dates.map {
            LimitsEntry(date: $0, snapshot: snapshot?.current(at: $0), provider: configuration.provider.providerID)
        }
        return Timeline(entries: entries, policy: .after(plan.reloadAfter))
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
        .description("Die Meter eines Anbieters mit Reset-Zeit und Pace-Marke – wie im Popover. Groß und extragroß zeigen alle Anbieter.")
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
        .widgetURL(WidgetLink.url(.init(page: .limits, provider: family.size.showsAllAccounts ? nil : shown)))
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
