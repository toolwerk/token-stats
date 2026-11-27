import AppKit
import SwiftUI
import TokenStatsCore

/// Popover, 372 pt breit: Kopf mit Seitenwahl · Tabs je Client · Seite · Fußzeile (SPEC §3).
struct PopoverView: View {
    let store: UsageStore
    let consumption: ConsumptionStore
    let settings: AppSettings
    let openSettings: () -> Void

    /// Gewähltes Konto (bzw. Anbieter-ID aus einem Widget-Link).
    @State private var selectedID: String?
    /// Zuletzt gewähltes Konto je Anbieter – ein Klick auf den Anbieter-Tab kehrt dorthin zurück.
    @State private var chosen: [String: String] = [:]
    /// Beim Öffnen steht immer „Limits“ – die Auswahl wird absichtlich nicht gemerkt.
    @State private var page: Page

    init(
        store: UsageStore, consumption: ConsumptionStore, settings: AppSettings,
        selectedID: String? = nil, showUsage: Bool = false,
        openSettings: @escaping () -> Void
    ) {
        self.store = store
        self.consumption = consumption
        self.settings = settings
        self.openSettings = openSettings
        _selectedID = State(initialValue: selectedID)
        _page = State(initialValue: showUsage ? .usage : .limits)
    }

    static let width: CGFloat = 372
    /// Seitenrand aller Blöcke im Popover.
    static let inset: CGFloat = 16

    var body: some View {
        // Ein Tab je Anbieter auf beiden Seiten, damit beim Seitenwechsel nichts springt
        // (SPEC §3.2). Die Konten wählt die Kontoleiste darunter, nur auf „Limits“.
        let accounts = store.sortedProviders
        let kinds = Self.firstPerKind(accounts)
        // Beim Öffnen ist das knappste Konto aktiv, die Reihenfolge bleibt fest.
        let activeID = selectedID ?? store.tightest?.providerID
        let active = accounts.first { $0.id == activeID }
            ?? accounts.first { $0.kind == activeID }
            ?? accounts.first
        let selected = page == .usage ? kinds.first { $0.kind == active?.kind } : active

        VStack(spacing: 0) {
            header
            if kinds.isEmpty {
                emptyState
            } else {
                tabBar(kinds, activeKind: active?.kind)
                if page == .limits, let kind = active?.kind, store.accounts(ofKind: kind).count > 1 {
                    accountBar(store.accounts(ofKind: kind), selected: active?.id)
                }
                Divider()
                if let selected {
                    ProviderPage(
                        provider: selected,
                        title: page == .usage ? selected.displayName : store.title(for: selected),
                        page: page,
                        state: store.states[selected.id] ?? .init(),
                        problem: page == .limits ? store.problem(for: selected) : nil,
                        isLoading: store.loading.contains(selected.id),
                        consumption: consumption,
                        showMoney: settings.showMoney,
                        subscription: subscription(kind: selected.kind),
                        accountCount: store.accounts(ofKind: selected.kind).count,
                        openSettings: openSettings
                    )
                }
            }
            Divider()
            footer(account: selected.flatMap { store.states[$0.id]?.snapshot?.account })
        }
        .frame(width: Self.width)
        .background {
            // ⌘, öffnet die Einstellungen, solange das Popover offen ist.
            Button("", action: openSettings).keyboardShortcut(",", modifiers: .command).hidden()
        }
    }

    static func firstPerKind(_ providers: [any UsageProvider]) -> [any UsageProvider] {
        var seen: Set<String> = []
        return providers.filter { seen.insert($0.kind).inserted }
    }

    /// Abo-Preis aller Konten eines Anbieters zusammen – zwei Max-Abos sind 400 $, nicht 200 $.
    private func subscription(kind: String) -> Int? {
        let prices = store.accounts(ofKind: kind).compactMap {
            SubscriptionPrice.dollars(provider: kind, plan: store.states[$0.id]?.snapshot?.account?.plan)
        }
        return prices.isEmpty ? nil : prices.reduce(0, +)
    }

    // MARK: Kopf

    private var header: some View {
        HStack(spacing: 8) {
            RobotIcon()
            Text("Token Stats").font(.system(size: 13.5, weight: .bold))
            Spacer()
            PageSwitch(selection: $page)
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: Tabs

    private func tabBar(_ kinds: [any UsageProvider], activeKind: String?) -> some View {
        let count = Self.visibleTabCount(kinds.map { ($0.displayName, nil) })
        let visible = kinds.prefix(count)
        let overflow = kinds.dropFirst(count)
        return HStack(spacing: 2) {
            ForEach(visible, id: \.kind) { item in
                TabButton(
                    title: item.displayName,
                    severity: kindSeverity(item.kind),
                    isActive: item.kind == activeKind
                ) { select(kind: item.kind) }
            }
            // „+n“ nur für Anbieter, nie für Konten – Konten stehen in der Kontoleiste.
            if !overflow.isEmpty {
                Menu("+\(overflow.count)") {
                    ForEach(overflow, id: \.kind) { item in
                        Button(item.displayName) { select(kind: item.kind) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 11.5, design: .monospaced))
            }
            Spacer()
        }
        .padding(.horizontal, Self.inset - 10)
    }

    /// Punkt im Anbieter-Tab: das knappste sichtbare Konto des Anbieters.
    private func kindSeverity(_ kind: String) -> Severity? {
        store.accounts(ofKind: kind).compactMap { store.states[$0.id]?.snapshot?.tightestWindow }
            .max { $0.percent < $1.percent }?.severity
    }

    /// Anbieter-Tab: zuletzt gewähltes Konto des Anbieters, sonst sein knappstes.
    private func select(kind: String) {
        let accounts = store.accounts(ofKind: kind)
        if let last = chosen[kind], accounts.contains(where: { $0.id == last }) {
            selectedID = last
            return
        }
        selectedID = accounts.max { a, b in
            (store.states[a.id]?.snapshot?.tightestWindow?.percent ?? -1) < (store.states[b.id]?.snapshot?.tightestWindow?.percent ?? -1)
        }?.id ?? kind
    }

    // MARK: Kontoleiste

    /// Chips je Konto unter den Anbieter-Tabs; bricht um, kürzt nichts, kein „+n“.
    private func accountBar(_ accounts: [any UsageProvider], selected: String?) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(accounts, id: \.id) { account in
                AccountChip(
                    label: store.label(for: account) ?? account.displayName,
                    severity: store.states[account.id]?.snapshot?.tightestWindow?.severity,
                    hasProblem: store.hasProblem(account),
                    isSelected: account.id == selected
                ) {
                    selectedID = account.id
                    chosen[account.kind] = account.id
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.inset)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// Wie viele Tabs in die Breite passen – gemessen statt fest, weil Konten-Tabs länger sind.
    static func visibleTabCount(_ titles: [(String, String?)]) -> Int {
        let available = width - 2 * (inset - 10)
        let overflowWidth: CGFloat = 40
        func tabWidth(_ title: String, _ label: String?) -> CGFloat {
            let bold = NSFont.systemFont(ofSize: 12, weight: .semibold)
            var text = (title as NSString).size(withAttributes: [.font: bold]).width
            if let label {
                text += 4 + (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
            }
            return ceil(text) + 5 + 5 + 20 + 2
        }
        let widths = titles.map(tabWidth)
        if widths.reduce(0, +) <= available { return titles.count }
        var used: CGFloat = 0
        var count = 0
        for width in widths {
            guard used + width + overflowWidth <= available else { break }
            used += width
            count += 1
        }
        return max(count, 1)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Kein Konto gefunden").font(.system(size: 12.5, weight: .semibold))
            Text("Melde dich in Claude Code oder Codex an. Weitere Ordner fügst du in den Einstellungen unter „Konten“ hinzu.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    // MARK: Fußzeile

    private func footer(account: AccountInfo?) -> some View {
        HStack(spacing: 8) {
            if let name = account?.name {
                HStack(spacing: 7) {
                    Text(name.prefix(1).uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 19, height: 19)
                        .background(Circle().fill(Color.accentColor))
                    Text(name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            if let last = store.lastUpdate {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Format.ago(last, now: context.date))
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            FooterButton(help: "Aktualisieren") {
                if store.loading.isEmpty {
                    Image(systemName: "arrow.clockwise")
                } else {
                    ProgressView().controlSize(.mini)
                }
            } action: {
                store.refresh(manual: true)
            }
            FooterButton(help: "Einstellungen (⌘,)") {
                Label("Einstellungen", systemImage: "gearshape")
            } action: {
                openSettings()
            }
        }
        // Gleicher Innenabstand links und rechts wie der übrige Inhalt (Dauerregel, Sven).
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5))
    }
}

private struct TabButton: View {
    let title: String
    let severity: Severity?
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(severity?.color ?? Color.secondary.opacity(0.4))
                    .frame(width: 5, height: 5)
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 9)
            .overlay(alignment: .bottom) {
                Rectangle().fill(isActive ? Color.accentColor : .clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Ein Konto in der Kontoleiste: Zustandspunkt und Bezeichnung, ungekürzt. Ein Konto mit
/// Fehler und ohne Stand ist grau und trägt ein „!“ (SPEC §6, Entwurf 27.11.2026).
private struct AccountChip: View {
    let label: String
    let severity: Severity?
    let hasProblem: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(hasProblem ? Color.secondary.opacity(0.4) : severity?.color ?? Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(label)
                    .fixedSize(horizontal: false, vertical: true)
                if hasProblem {
                    Text("!").fontWeight(.bold)
                }
            }
            // Gleiche Schrift gewählt und nicht gewählt – sonst springt die Breite der Chips.
            .font(.system(size: 11.5))
            .foregroundStyle(hasProblem ? .secondary : isSelected ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.3)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(hasProblem ? "\(label): Fehler, Details auf der Seite" : label)
    }
}

private struct FooterButton<Content: View>: View {
    let help: String
    @ViewBuilder let content: Content
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            content
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 7)
                .frame(minWidth: 26, minHeight: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

// MARK: - Seiten „Limits“ und „Verbrauch“

private enum Page: String, CaseIterable {
    case limits = "Limits", usage = "Verbrauch"
}

/// Schlanker Umschalter in der Kopfzeile – bewusst leiser als ein Segmented Control.
private struct PageSwitch: View {
    @Binding var selection: Page

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Page.allCases, id: \.self) { option in
                let isOn = option == selection
                Button { selection = option } label: {
                    Text(option.rawValue)
                        .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? .primary : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background {
                            if isOn {
                                Capsule()
                                    .fill(.background)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
        .animation(.easeOut(duration: 0.12), value: selection)
    }
}

private struct ProviderPage: View {
    let provider: any UsageProvider
    /// „Claude · frank“ auf „Limits“, nur „Claude“ auf „Verbrauch“.
    let title: String
    let page: Page
    let state: UsageStore.ProviderState
    /// Satz, warum das Konto nicht abgefragt werden kann (Ordner fehlt, keine Anmeldung).
    let problem: String?
    let isLoading: Bool
    let consumption: ConsumptionStore
    let showMoney: Bool
    /// Abo-Preis aller Konten des Anbieters.
    let subscription: Int?
    let accountCount: Int
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                if page == .usage, accountCount > 1 {
                    Text("\(accountCount) Konten").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                } else if let plan = state.snapshot?.account?.plan {
                    Text(plan).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                if page == .limits, let tightest = state.snapshot?.tightestWindow {
                    Text(Format.percent(tightest.percent))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tightest.severity.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(tightest.severity.color))
                }
            }

            if page == .usage {
                UsageView(
                    providerID: provider.kind,
                    consumption: consumption,
                    showMoney: showMoney,
                    subscription: subscription,
                    accountCount: accountCount
                )
            } else {
                limits
            }
        }
        .padding(.horizontal, PopoverView.inset)
        .padding(.top, 16)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var limits: some View {
        if let problem {
            Label { CommandText(problem) } icon: { Image(systemName: "exclamationmark.triangle") }
                .font(.system(size: 11))
                .foregroundStyle(Severity.crit.color)
                .fixedSize(horizontal: false, vertical: true)
            Button("Einstellungen öffnen", action: openSettings)
        } else {
            limitsContent
        }
    }

    @ViewBuilder
    private var limitsContent: some View {
            // Abruffehler (z. B. Anmeldung abgelaufen): nur der Satz, kein „Einstellungen öffnen“ –
            // den gibt es nur bei Einrichtungsfehlern (oben, `problem`).
            StatusLine(state: state)

            if let snapshot = state.snapshot {
                VStack(spacing: 18) {
                    ForEach(snapshot.windows) { MeterRow(window: $0) }
                }
                if !snapshot.extras.isEmpty {
                    Divider()
                    FlowLayout(spacing: 8) {
                        ForEach(snapshot.extras) { extra in
                            Text(extra.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                        }
                    }
                }
            } else if isLoading {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 20)
            }
    }
}

/// Hinweis bei Rate-Limit oder Fehler – die letzten Werte bleiben darunter sichtbar.
private struct StatusLine: View {
    let state: UsageStore.ProviderState

    var body: some View {
        if let retryAt = state.retryAt, state.isRateLimited {
            label("pause.circle", "Abfrage pausiert (Rate-Limit) · wieder ab \(Format.reset(retryAt))", .warn)
        } else if let error = state.error {
            label("exclamationmark.triangle", state.snapshot == nil ? error : "\(error) Zeige letzten Stand.", .crit)
        } else if let note = state.note {
            let stand = state.snapshot.map { " Abgefragt \(Format.ago($0.fetchedAt))." } ?? ""
            label("clock", note + stand, nil)
        }
    }

    private func label(_ symbol: String, _ text: String, _ severity: Severity?) -> some View {
        Label { CommandText(text) } icon: { Image(systemName: symbol) }
            .font(.system(size: 11))
            .foregroundStyle(severity.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Chips nebeneinander, bei Platzmangel in die nächste Zeile – Ollama meldet je Modell einen.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
