import Foundation
import Testing
@testable import TokenStatsCore

// Neuladen und Timeline der Widgets (SPEC §7 „Widgets“) – nur Demo-Werte.

private let berlin: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return calendar
}()

/// 27.11.2026, 12:05:30 in Berlin.
private let now = berlin.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 12, minute: 5, second: 30))!

private func snapshot(fetchedAt: Date = now, percent: Double = 0.42, resetsAt: Date? = now.addingTimeInterval(2 * 3600),
                      tokens: Int = 1000, rateLimited: Bool = false, message: String? = nil,
                      showMoney: Bool = true, todayDay: Date? = nil) -> WidgetSnapshot {
    let window = LimitWindow(id: "session", name: "Session", scopeNote: "5 h", percent: percent,
                             resetsAt: resetsAt, windowLength: 5 * 3600)
    let provider = WidgetSnapshot.Provider(
        id: "claude", name: "Claude",
        snapshot: ProviderSnapshot(account: AccountInfo(name: "Demo", plan: "Max"), windows: [window], fetchedAt: fetchedAt),
        isRateLimited: rateLimited, message: message
    )
    var summary = UsageSummary()
    summary.total = TokenCounts(input: tokens)
    summary.days = [UsageSummary.DayTotal(day: todayDay ?? berlin.startOfDay(for: now), tokens: tokens)]
    return WidgetSnapshot(writtenAt: fetchedAt, showMoney: showMoney, providers: [provider],
                          usage: [WidgetSnapshot.Usage(provider: "claude", period: .today, summary: summary)])
}

@Suite struct WidgetReloadTests {
    @Test func firstSnapshotReloads() {
        #expect(WidgetReload.decide(shown: nil, current: snapshot(), lastReload: .distantPast, now: now) == .now)
    }

    @Test func newFetchTimeAloneIsNoChange() {
        let shown = snapshot()
        let refetched = snapshot(fetchedAt: now.addingTimeInterval(300))
        #expect(shown != refetched)
        #expect(!WidgetReload.limitsChanged(from: shown, to: refetched))
        #expect(WidgetReload.decide(shown: shown, current: refetched, lastReload: now.addingTimeInterval(-3600),
                                    now: now.addingTimeInterval(300)) == .skip)
    }

    @Test func resetJitterBelowAMinuteIsNoChange() {
        let reset = now.addingTimeInterval(7200)
        #expect(!WidgetReload.limitsChanged(from: snapshot(resetsAt: reset), to: snapshot(resetsAt: reset.addingTimeInterval(0.7))))
    }

    @Test func contentChangesReloadImmediately() {
        let shown = snapshot()
        let changes = [
            snapshot(percent: 0.43),
            snapshot(resetsAt: now.addingTimeInterval(5 * 3600)),
            snapshot(resetsAt: nil),
            snapshot(rateLimited: true),
            snapshot(message: "Anmeldung abgelaufen"),
            snapshot(showMoney: false),
        ]
        for changed in changes {
            #expect(WidgetReload.limitsChanged(from: shown, to: changed))
            #expect(WidgetReload.decide(shown: shown, current: changed, lastReload: now, now: now) == .now)
        }
        var machine = snapshot()
        machine.machine = "work"
        #expect(WidgetReload.limitsChanged(from: shown, to: machine))
        var fewer = snapshot()
        fewer.providers = []
        #expect(WidgetReload.limitsChanged(from: shown, to: fewer))
    }

    @Test func usageAloneWaitsForTheInterval() {
        let shown = snapshot()
        let more = snapshot(fetchedAt: now.addingTimeInterval(60), tokens: 2000)
        let lastReload = now.addingTimeInterval(-100)
        #expect(WidgetReload.decide(shown: shown, current: more, lastReload: lastReload, now: now)
            == .at(lastReload.addingTimeInterval(300)))
        #expect(WidgetReload.decide(shown: shown, current: more, lastReload: now.addingTimeInterval(-300), now: now) == .now)
    }
}

@Suite struct WidgetTimelineTests {
    @Test func quarterHourGridAfterNow() {
        let plan = WidgetTimeline.plan(now: now, snapshot: nil, calendar: berlin)
        #expect(plan.dates.first == now)
        let quarter = berlin.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 12, minute: 15))!
        #expect(plan.dates[1] == quarter)
        #expect(plan.dates[2] == quarter.addingTimeInterval(900))
        // 6 h Horizont: 12:15 … 18:00 = 24 Rasterpunkte, dazu jetzt.
        #expect(plan.dates.count == 25)
        #expect(plan.reloadAfter == plan.dates.last)
        #expect(plan.reloadAfter <= now.addingTimeInterval(WidgetTimeline.horizon))
        #expect(plan.dates == plan.dates.sorted())
    }

    @Test func includesResetsAndMidnightSortedWithoutDuplicates() {
        let evening = berlin.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 21, minute: 50))!
        let midnight = berlin.date(from: DateComponents(year: 2026, month: 11, day: 28))!
        // Reset mit Sekundenbruchteil kurz nach 23:07, ein zweiter genau um Mitternacht.
        let reset = midnight.addingTimeInterval(-53 * 60 + 0.4)
        var state = snapshot(fetchedAt: evening, resetsAt: reset)
        state.providers[0].snapshot?.windows.append(
            LimitWindow(id: "week", name: "Woche", percent: 0.5, resetsAt: midnight, windowLength: 7 * 86400))
        let plan = WidgetTimeline.plan(now: evening, snapshot: state, calendar: berlin)

        #expect(plan.dates.contains(Date(timeIntervalSinceReferenceDate: reset.timeIntervalSinceReferenceDate.rounded(.up))))
        #expect(plan.dates.filter { $0 == midnight }.count == 1)
        #expect(plan.dates == plan.dates.sorted())
        #expect(Set(plan.dates).count == plan.dates.count)
        #expect(plan.dates.allSatisfy { $0 >= evening && $0 <= evening.addingTimeInterval(WidgetTimeline.horizon) })
    }

    @Test func skipsPastAndFarResets() {
        let past = snapshot(resetsAt: now.addingTimeInterval(-60))
        let far = snapshot(resetsAt: now.addingTimeInterval(3 * 86400))
        let grid = WidgetTimeline.plan(now: now, snapshot: nil, calendar: berlin).dates
        #expect(WidgetTimeline.plan(now: now, snapshot: past, calendar: berlin).dates == grid)
        #expect(WidgetTimeline.plan(now: now, snapshot: far, calendar: berlin).dates == grid)
    }

    @Test func endOfTheSnapshotsDayCountsInOtherTimeZones() {
        // Mac in Berlin, iPhone in New York: „Heute“ des Macs endet um 18:00 Ortszeit New York,
        // lange vor der Mitternacht des iPhones.
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let state = snapshot(resetsAt: nil)
        let macDayEnd = berlin.date(from: DateComponents(year: 2026, month: 11, day: 28))!
        let phoneNow = macDayEnd.addingTimeInterval(-2 * 3600 - 7)
        let plan = WidgetTimeline.plan(now: phoneNow, snapshot: state, calendar: newYork)
        #expect(plan.dates.contains(macDayEnd))
        #expect(!plan.dates.contains(newYork.date(byAdding: .day, value: 1, to: newYork.startOfDay(for: phoneNow))!))
    }
}

@Suite struct WidgetSnapshotAtTests {
    @Test func rollsOverPassedResets() {
        let reset = now.addingTimeInterval(600)
        let state = snapshot(percent: 0.9, resetsAt: reset)
        #expect(state.current(at: now, calendar: berlin).providers[0].snapshot?.windows[0].percent == 0.9)
        let after = state.current(at: reset.addingTimeInterval(1), calendar: berlin).providers[0].snapshot?.windows[0]
        #expect(after?.percent == 0)
        #expect(after?.resetsAt == reset.addingTimeInterval(5 * 3600))
    }

    @Test func todayDisappearsAfterMidnight() {
        let state = snapshot()
        #expect(state.current(at: now, calendar: berlin).summary(provider: nil, period: .today)?.total.input == 1000)
        let midnight = berlin.date(from: DateComponents(year: 2026, month: 11, day: 28))!
        #expect(state.current(at: midnight.addingTimeInterval(-1), calendar: berlin).summary(provider: nil, period: .today) != nil)
        #expect(state.current(at: midnight, calendar: berlin).summary(provider: nil, period: .today) == nil)
        // Andere Perioden bleiben stehen – die rechnet nur die App neu.
        var week = snapshot()
        week.usage[0].period = .week
        #expect(week.current(at: midnight.addingTimeInterval(86400), calendar: berlin).summary(provider: nil, period: .week) != nil)
    }
}

@Suite struct AppGroupTests {
    @Test func acceptsOnlyCompleteIdentifiers() {
        #expect(AppGroup.resolve("TEAMID1234.de.mahype.TokenStats") == "TEAMID1234.de.mahype.TokenStats")
        #expect(AppGroup.resolve("TEAMID1234.de.mahype.TokenStats.debug") == "TEAMID1234.de.mahype.TokenStats.debug")
        #expect(AppGroup.resolve("group.de.mahype.TokenStats") == "group.de.mahype.TokenStats")
        // Ad hoc: DEVELOPMENT_TEAM leer → nur „.de.mahype…“; kein Rückfall auf die Release-Gruppe.
        #expect(AppGroup.resolve(".de.mahype.TokenStats") == nil)
        #expect(AppGroup.resolve(".de.mahype.TokenStats.debug") == nil)
        #expect(AppGroup.resolve("$(APP_GROUP)") == nil)
        #expect(AppGroup.resolve("") == nil)
        #expect(AppGroup.resolve(nil) == nil)
        #expect(AppGroup.resolve(42) == nil)
    }
}
