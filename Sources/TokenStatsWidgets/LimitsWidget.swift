import AppIntents
import SwiftUI
import TokenStatsCore
import WidgetKit

// MARK: Konfiguration

/// Früherer Parameter „Anbieter“ (bis PR #2). Bleibt mit unverändertem Typ und Namen im
/// Intent, damit WidgetKit gespeicherte Widgets ohne Typumwandlung weiter liest: Ein Widget
/// auf „Claude“ zeigt nach dem Update das Standardkonto wie vorher und springt nicht auf
/// „Knappstes Limit“ (Sven, 27.11.2026). Im Dialog „Widget bearbeiten“ ist er ausgeblendet
/// (`parameterSummary`); sobald jemand ein Konto wählt, gilt `account`.
enum LimitsProviderOption: String, AppEnum {
    case tightest, antigravity, claude, codex, ollama

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Anbieter")
    static let caseDisplayRepresentations: [LimitsProviderOption: DisplayRepresentation] = [
        .tightest: "Knappstes Limit", .antigravity: "Antigravity", .claude: "Claude", .codex: "Codex", .ollama: "Ollama",
    ]
}

/// Konto für das Widget „Limits“, dynamisch aus dem Widget-Stand (SPEC §6 „Mehrere Konten“):
/// „Knappstes Limit“, dann je Anbieter seine Konten, bei mehreren zuerst „Claude – knappstes
/// Konto“ (`claude@knappstes`). Auflösung und Titel liegen in `LimitsAccounts` (TokenStatsCore).
struct LimitsAccountEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Konto"
    static let defaultQuery = LimitsAccountQuery()

    let id: String
    let name: String
    /// „alle Konten“, „Standard“, „wechselt von selbst“, „nicht mehr da“.
    let detail: String?

    init(_ choice: LimitsAccounts.Choice) {
        id = choice.id
        name = choice.title
        detail = choice.subtitle
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: detail.map { "\($0)" })
    }
}

struct LimitsAccountQuery: EntityStringQuery {
    /// Gespeicherte Kennungen auflösen – auch alte Enum-Werte und Konten, die nicht mehr im
    /// Stand stehen („nicht mehr da“, mit letztem Namen statt `claude@…`).
    func entities(for identifiers: [String]) async throws -> [LimitsAccountEntity] {
        let snapshot = WidgetSnapshot.loadForWidgets()
        return identifiers.map { LimitsAccountEntity(LimitsAccounts.choice(for: $0, in: snapshot)) }
    }

    /// Gruppiert: „Knappstes Limit“, dann je Anbieter seine Konten, Standardkonto markiert.
    func suggestedEntities() async throws -> IntentItemCollection<LimitsAccountEntity> {
        let groups = LimitsAccounts.groups(WidgetSnapshot.loadForWidgets())
        return IntentItemCollection(sections: groups.map { group in
            let items = group.choices.map { IntentItem(LimitsAccountEntity($0)) }
            guard let title = group.title else { return IntentItemSection(items: items) }
            return IntentItemSection("\(title)", items: items)
        })
    }

    /// Suchfeld der Systemliste – bei vielen Konten.
    func entities(matching string: String) async throws -> IntentItemCollection<LimitsAccountEntity> {
        let choices = LimitsAccounts.choices(matching: string, in: WidgetSnapshot.loadForWidgets())
        return IntentItemCollection(items: choices.map(LimitsAccountEntity.init))
    }

    func defaultResult() async -> LimitsAccountEntity? { LimitsAccountEntity(LimitsAccounts.tightestChoice) }
}

struct LimitsConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Limits"
    static let description = IntentDescription("Session- und Wochenlimit mit Pace-Marke aus Token Stats.")

    /// Alter Parameter, nur noch gelesen (siehe `LimitsProviderOption`).
    @Parameter(title: "Anbieter", default: .tightest)
    var provider: LimitsProviderOption

    @Parameter(title: "Konto")
    var account: LimitsAccountEntity?

    static var parameterSummary: some ParameterSummary {
        Summary { \.$account }
    }

    /// Kennung des gezeigten Kontos; `nil` = knappstes Limit über alle Konten.
    var selection: String? {
        LimitsAccounts.selection(account: account?.id, legacy: provider.rawValue)
    }
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
        return LimitsEntry(date: .now, snapshot: snapshot, provider: configuration.selection)
    }

    func timeline(for configuration: LimitsConfigurationIntent, in context: Context) async -> Timeline<LimitsEntry> {
        let entry = LimitsEntry(date: .now, snapshot: WidgetSnapshot.loadForWidgets(), provider: configuration.selection)
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
