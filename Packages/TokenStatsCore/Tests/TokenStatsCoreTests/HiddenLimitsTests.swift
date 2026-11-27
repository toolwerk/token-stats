import Foundation
import Testing
@testable import TokenStatsCore

// „+N Limits“ im Kopf des kleinen und mittleren Widgets (Sven, 27.11.2026): Limits, die nicht
// hineinpassen, fallen nicht still weg. Nur Demo-Werte.

@Suite struct HiddenLimitsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func windows(_ percents: [Double]) -> [LimitWindow] {
        percents.enumerated().map { LimitWindow(id: "w\($0.offset)", name: "Limit \($0.offset)", percent: $0.element) }
    }

    @Test func singularAndPlural() {
        #expect(LimitsAccounts.hiddenLimitsText(0) == nil)
        #expect(LimitsAccounts.hiddenLimitsText(1) == "+1 Limit")
        #expect(LimitsAccounts.hiddenLimitsText(2) == "+2 Limits")
        #expect(LimitsAccounts.hiddenLimitsText(5) == "+5 Limits")
    }

    @Test func smallShowsTwoTightestAndCountsTheRest() {
        // Demo-Claude: Session 42 %, Woche 82 %, Opus 64 % – klein zeigt höchstens 2.
        let claude = DemoData.snapshots(now: now)["claude"]!.windows
        let picked = LimitsAccounts.pick(claude, maximum: 2)
        #expect(picked.shown.map(\.name) == ["Woche", "Opus"], "die knappsten, in der Reihenfolge der App")
        #expect(picked.hidden == 1)
        #expect(LimitsAccounts.hiddenLimitsText(picked.hidden) == "+1 Limit")
    }

    @Test func mediumShowsFourAndCountsTheRest() {
        let picked = LimitsAccounts.pick(windows([0.1, 0.9, 0.5, 0.3, 0.7, 0.2]), maximum: 4)
        #expect(picked.shown.map(\.id) == ["w1", "w2", "w3", "w4"])
        #expect(picked.hidden == 2)
        #expect(LimitsAccounts.hiddenLimitsText(picked.hidden) == "+2 Limits")
    }

    @Test func nothingHiddenWhenAllFit() {
        let picked = LimitsAccounts.pick(windows([0.4, 0.8]), maximum: 2)
        #expect(picked.shown.count == 2)
        #expect(picked.hidden == 0)
        #expect(LimitsAccounts.hiddenLimitsText(picked.hidden) == nil)
        #expect(LimitsAccounts.pick(windows([0.4, 0.8, 0.1]), maximum: 1).hidden == 2, "Stufe mit nur einem Limit")
    }
}
