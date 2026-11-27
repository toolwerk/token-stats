import SwiftUI

/// Großes Widget „Limits“ bei vielen Konten: eine Zeile je Konto mit seinem knappsten Limit
/// (Entwurf „Widgets einheitlich“ §3 „Kontozeile“, Stufen L3/L4). Konten ohne Stand stehen
/// oben mit ihrem Hinweis. Passt nicht jede Zeile, fasst die Sammelzeile den Rest zusammen –
/// nie fällt ein Konto still heraus.
///
/// Maße nach dem Entwurf: Limitname 70 pt, Balken 72 pt, Prozent 38 pt („100 %“ bricht nicht um),
/// Spaltenabstand 8, Zeile mind. 20 pt, Trennlinie 0,5 pt.
///
/// Die Tabelle bricht nie mitten im Wort (Entwurf §11). Passt ein Wort eines Kontonamens nicht
/// in die Spalte „Konto“ (etwa „Verwaltungsgesellschaft“), nimmt sie die Stufe L5: ohne
/// Limitnamen-Spalte, die Kontospalte 78 pt breiter, der Limitname klein unter dem Konto.
struct LimitsAccountTable: View {
    let rows: [LimitsAccounts.Row]
    /// Gezeigte Zeilen; der Rest steht in der Sammelzeile.
    let shown: Int
    var now: Date = .now
    /// Stufe L5: Limitname unter dem Konto statt in eigener Spalte.
    var stacked = false

    nonisolated static let limitWidth: CGFloat = 70
    nonisolated static let barWidth: CGFloat = 72
    nonisolated static let percentWidth: CGFloat = 38
    nonisolated static let nameSize: CGFloat = 11

    /// Breite der Spalte „Konto“ bei `total` Tabellenbreite.
    nonisolated static func nameWidth(total: CGFloat, stacked: Bool) -> CGFloat {
        stacked ? total - barWidth - percentWidth - 16 : total - limitWidth - barWidth - percentWidth - 24
    }

    /// Spielraum der Spalte „Konto“ (Entwurf §5): Ein Name, der nur knapp hineinpasst
    /// („MÖBELWERKSTATT“ 103,15 pt in 104 pt), gilt als zu breit – Rundung und Kerning dürfen
    /// nicht entscheiden, ob er im Wort bricht.
    nonisolated static let columnSlack: CGFloat = 2
    /// Höchstens so viele Zeilen darf ein Kontoname in der Tabelle belegen (Entwurf §11).
    nonisolated static let maxNameLines = 3

    /// Braucht die Tabelle bei dieser Breite die Stufe L5? Ja, wenn ein Wort eines Kontonamens
    /// nicht in die Spalte „Konto“ passt (sonst bräche es im Wort) oder wenn ein Name mit dem
    /// echten Umbruch mehr als drei Zeilen bräuchte – jeweils mit 2 pt Spielraum.
    nonisolated static func needsStacked(_ rows: [LimitsAccounts.Row], total: CGFloat) -> Bool {
        let available = nameWidth(total: total, stacked: false) - columnSlack
        return rows.contains { row in
            let prefix = row.provider.providerName + " · "
            let usedPrefix = row.provider.name.hasPrefix(prefix) ? prefix : nil
            let word = WrappedTitle.widestUnbreakable(row.provider.name, size: nameSize, prefix: usedPrefix,
                                                      prefixWeight: .semibold, accountWeight: .regular)
            if word > available { return true }
            let lines = WrappedTitle.lineCount(row.provider.name, size: nameSize, prefix: usedPrefix,
                                               prefixWeight: .semibold, accountWeight: .regular, available: available)
            return lines > maxNameLines
        }
    }

    private var limitColumns: CGFloat {
        (stacked ? 0 : Self.limitWidth + 8) + Self.barWidth + Self.percentWidth + 8
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Konto").frame(maxWidth: .infinity, alignment: .leading)
                Text("Knappstes Limit").frame(width: limitColumns, alignment: .leading)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
            ForEach(rows.prefix(shown)) { row in
                Divider()
                AccountRow(row: row, now: now, stacked: stacked, limitColumns: limitColumns)
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
        let stacked: Bool
        let limitColumns: CGFloat

        var body: some View {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    name
                    // L5: Limitname klein unter dem Konto.
                    if stacked, let window = row.window { limitName(window) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let window = row.window {
                    if !stacked {
                        limitName(window).frame(width: LimitsAccountTable.limitWidth, alignment: .leading)
                    }
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
                    Label { CommandText(row.provider.message ?? "Noch kein Stand.") } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: limitColumns, alignment: .leading)
                }
            }
            .padding(.vertical, 3)
            .frame(minHeight: 20)
        }

        private func limitName(_ window: LimitWindow) -> some View {
            Group {
                if row.provider.isRateLimited {
                    Image(systemName: "pause.fill").font(.system(size: 9))
                } else {
                    Text(window.name).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }

        /// „Claude · Kunde A“: Anbieter semibold, Kontoteil regular; Trennpunkt vorn in der
        /// neuen Zeile, wenn „· Kunde A“ dort passt (gemessen, `TitleWrap`).
        private var name: some View {
            let kind = row.provider.providerName
            let full = row.provider.name
            let prefix = kind + " · "
            return WrappedTitle(full, size: LimitsAccountTable.nameSize, prefix: full.hasPrefix(prefix) ? prefix : nil,
                                prefixWeight: .semibold, accountWeight: .regular)
        }
    }
}
