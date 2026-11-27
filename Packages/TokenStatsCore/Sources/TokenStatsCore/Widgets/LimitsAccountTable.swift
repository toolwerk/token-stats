import SwiftUI

/// Großes Widget „Limits“ bei vielen Konten: eine Zeile je Konto mit seinem knappsten Limit
/// (Entwurf „Widgets einheitlich“ §3 „Kontozeile“, Stufen L3/L4). Konten ohne Stand stehen
/// oben mit ihrem Hinweis. Passt nicht jede Zeile, fasst die Sammelzeile den Rest zusammen –
/// nie fällt ein Konto still heraus.
///
/// Maße nach dem Entwurf: Limitname 70 pt, Balken 72 pt, Prozent 38 pt („100 %“ bricht nicht um),
/// Spaltenabstand 8, Zeile mind. 20 pt, Trennlinie 0,5 pt.
struct LimitsAccountTable: View {
    let rows: [LimitsAccounts.Row]
    /// Gezeigte Zeilen; der Rest steht in der Sammelzeile.
    let shown: Int
    var now: Date = .now

    static let limitWidth: CGFloat = 70
    static let barWidth: CGFloat = 72
    static let percentWidth: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Konto").frame(maxWidth: .infinity, alignment: .leading)
                Text("Knappstes Limit").frame(width: Self.limitWidth + Self.barWidth + Self.percentWidth + 16, alignment: .leading)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
            ForEach(rows.prefix(shown)) { row in
                Divider()
                AccountRow(row: row, now: now)
            }
            if shown < rows.count {
                Divider()
                Text(LimitsAccounts.overflowText(rows.dropFirst(shown)))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    private struct AccountRow: View {
        let row: LimitsAccounts.Row
        let now: Date

        var body: some View {
            HStack(alignment: .center, spacing: 8) {
                name
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let window = row.window {
                    Group {
                        if row.provider.isRateLimited {
                            Image(systemName: "pause.fill").font(.system(size: 9))
                        } else {
                            Text(window.name).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: LimitsAccountTable.limitWidth, alignment: .leading)
                    MeterBar(percent: window.percent, elapsed: window.elapsedFraction(now: now), color: window.severity.color)
                        .frame(width: LimitsAccountTable.barWidth, height: 4)
                    Text(Format.percent(window.percent))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(window.severity.color)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: LimitsAccountTable.percentWidth, alignment: .trailing)
                } else {
                    Label(row.provider.message ?? "Noch kein Stand.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: LimitsAccountTable.limitWidth + LimitsAccountTable.barWidth + LimitsAccountTable.percentWidth + 16,
                               alignment: .leading)
                }
            }
            .padding(.vertical, 3)
            .frame(minHeight: 20)
        }

        /// „Claude · Kunde A“: Anbieter semibold, Kontoteil regular.
        private var name: Text {
            let kind = row.provider.providerName
            let full = row.provider.name
            let prefix = kind + " · "
            guard full.hasPrefix(prefix) else { return Text(full).fontWeight(.semibold) }
            return Text(kind + " · ").fontWeight(.semibold) + Text(String(full.dropFirst(prefix.count)))
        }
    }
}
