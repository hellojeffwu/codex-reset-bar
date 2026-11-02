import Foundation

@main
struct ReminderRulesTests {
    static var checks = 0
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }

    static func snapshot(_ remaining: Double?, account: String? = "private-account-a",
                         allowed: Bool? = true, minutes: Int? = 10_080,
                         resetAfter: Double? = 1_800, secondary: Double? = nil) -> UsageSnapshot {
        let reset = resetAfter.map { Int(start.addingTimeInterval($0).timeIntervalSince1970) }
        let bucket = QuotaBucket(limitId: "codex", limitName: nil, normalModelSlug: nil,
                                 primary: remaining.map { QuotaWindow(usedPercent: 100 - $0, windowDurationMins: minutes, resetsAt: reset) },
                                 secondary: secondary.map { QuotaWindow(usedPercent: 100 - $0, windowDurationMins: 300, resetsAt: reset) },
                                 credits: nil, spendControlReached: nil, planType: "pro", rateLimitReachedType: nil)
        return UsageSnapshot(ordinaryUsageAllowed: allowed, rateLimits: bucket, rateLimitsByLimitId: nil, accountId: account)
    }

    static func main() throws {
        let low = ReminderRule.presets[0]
        let soon = ReminderRule.presets[2]
        expect(ReminderRule.presets.count == 6, "six requested presets")
        expect(Set(ReminderRule.presets.map(\.id)).count == 6, "preset IDs are unique")
        expect(ReminderRule.presets.filter { $0.kind == .quotaBelow }.map(\.threshold) == [20, 10], "20 and 10 percent presets")
        expect(!ReminderRule.presets.contains { $0.kind == .scheduled }, "no arbitrary scheduled preset")
        expect(ReminderKind.allCases.count == 6 && ReminderKind.allCases.allSatisfy { !$0.title.isEmpty }, "all kinds have display labels")

        var quota = NodeDetector()
        expect(quota.ingest(snapshot(40), rules: [low], at: start).isEmpty, "first read establishes quota baseline")
        let crossed = quota.ingest(snapshot(20, allowed: false), rules: [low], at: start.addingTimeInterval(60))
        expect(crossed.count == 1 && crossed[0].body.contains("剩余 20%"), "crossing includes exact threshold without permission gate")
        expect(!crossed[0].body.contains("private-account"), "notification never includes account identity")
        expect(quota.ingest(snapshot(10), rules: [low], at: start.addingTimeInterval(120)).isEmpty, "continued low quota stays quiet")
        _ = quota.ingest(snapshot(20.5), rules: [low], at: start.addingTimeInterval(180))
        expect(quota.ingest(snapshot(20), rules: [low], at: start.addingTimeInterval(240)).isEmpty, "small oscillation does not rearm")
        _ = quota.ingest(snapshot(21), rules: [low], at: start.addingTimeInterval(300))
        expect(quota.ingest(snapshot(19, allowed: nil), rules: [low], at: start.addingTimeInterval(360)).count == 1, "one point recovery rearms even with unknown permission")

        var initiallyLow = NodeDetector()
        expect(initiallyLow.ingest(snapshot(5), rules: [low], at: start).isEmpty, "already low on install is not retroactively alerted")
        expect(initiallyLow.ingest(snapshot(1), rules: [low], at: start.addingTimeInterval(30)).isEmpty, "initial low baseline remains quiet")

        var absent = NodeDetector()
        _ = absent.ingest(snapshot(50), rules: [low], at: start)
        expect(absent.ingest(snapshot(nil), rules: [low], at: start.addingTimeInterval(30)).isEmpty, "missing quota window is not zero")
        expect(absent.ingest(nil, rules: [low], at: start.addingTimeInterval(60)).isEmpty, "network failure cannot emit quota reminder")
        expect(absent.ingest(snapshot(10), rules: [low], at: start.addingTimeInterval(90)).count == 1, "missing window retains valid threshold baseline")

        var accounts = NodeDetector()
        _ = accounts.ingest(snapshot(50), rules: [low], at: start)
        expect(accounts.ingest(snapshot(10, account: "private-account-b"), rules: [low], at: start.addingTimeInterval(30)).isEmpty, "new account rebaselines")
        _ = accounts.ingest(snapshot(50, account: "private-account-b"), rules: [low], at: start.addingTimeInterval(60))
        expect(accounts.ingest(snapshot(10, account: nil), rules: [low], at: start.addingTimeInterval(90)).isEmpty, "unknown account cannot be compared")
        expect(accounts.ingest(snapshot(10, account: "private-account-b"), rules: [low], at: start.addingTimeInterval(120)).isEmpty, "account returning after unknown rebaselines")

        var changed = NodeDetector()
        _ = changed.ingest(snapshot(50), rules: [low], at: start)
        var edited = low
        edited.threshold = 40
        expect(changed.ingest(snapshot(30), rules: [edited], at: start.addingTimeInterval(30)).isEmpty, "threshold change creates baseline")
        edited.title = "我的标题"
        edited.body = "我的文案"
        edited.sound = false
        edited.popup = false
        edited.phone = true
        expect(changed.ingest(snapshot(10), rules: [edited], at: start.addingTimeInterval(60)).isEmpty, "text and channel edits do not replay history")
        _ = changed.ingest(snapshot(50), rules: [edited], at: start.addingTimeInterval(90))
        let custom = changed.ingest(snapshot(40), rules: [edited], at: start.addingTimeInterval(120))
        expect(custom.count == 1 && custom[0].title == edited.title && custom[0].body.hasPrefix(edited.body), "custom copy is preserved")
        expect(!custom[0].sound && !custom[0].popup && custom[0].phone && custom[0].ruleID == edited.id, "custom delivery choices are preserved")
        edited.enabled = false
        expect(changed.ingest(snapshot(70), rules: [edited], at: start.addingTimeInterval(150)).isEmpty, "disabled rule never alerts")
        edited.enabled = true
        expect(changed.ingest(snapshot(5), rules: [edited], at: start.addingTimeInterval(180)).isEmpty, "enabling a low rule does not replay history")

        var windows = NodeDetector()
        _ = windows.ingest(snapshot(50, secondary: 60), rules: [low], at: start)
        let merged = windows.ingest(snapshot(10, secondary: 15), rules: [low], at: start.addingTimeInterval(30))
        expect(merged.count == 1 && merged[0].body.components(separatedBy: "\n").count == 3, "multiple windows merge within one rule")
        var duration = NodeDetector()
        _ = duration.ingest(snapshot(50), rules: [low], at: start)
        expect(duration.ingest(snapshot(5, minutes: 300), rules: [low], at: start.addingTimeInterval(30)).isEmpty, "changed window duration rebaselines")

        var expected = NodeDetector()
        expect(expected.ingest(snapshot(50), rules: [soon], at: start).isEmpty, "reset timer starts outside lead")
        expect(expected.ingest(nil, rules: [soon], at: start.addingTimeInterval(1_250)).isEmpty, "clock tick alone cannot use stale reset time")
        let approaching = expected.ingest(snapshot(50), rules: [soon], at: start.addingTimeInterval(1_260))
        expect(approaching.count == 1 && approaching[0].body.contains("是否恢复仍以实际检测为准"), "fresh lead transition alerts as estimate only")
        expect(expected.ingest(snapshot(50), rules: [soon], at: start.addingTimeInterval(1_300)).isEmpty, "same reset timestamp alerts once")
        var resumed = try JSONDecoder().decode(NodeDetector.self, from: JSONEncoder().encode(expected))
        expect(resumed.ingest(snapshot(50), rules: [soon], at: start.addingTimeInterval(1_350)).isEmpty, "restart preserves reset deduplication")
        _ = resumed.ingest(snapshot(50), rules: [soon], at: start.addingTimeInterval(600))
        expect(resumed.ingest(snapshot(50), rules: [soon], at: start.addingTimeInterval(1_300)).isEmpty, "clock rollback cannot repeat a timestamp reminder")
        expect(resumed.ingest(snapshot(50, resetAfter: 3_600), rules: [soon], at: start.addingTimeInterval(1_400)).isEmpty, "new future reset timestamp establishes new cycle")
        expect(resumed.ingest(snapshot(50, resetAfter: 3_600), rules: [soon], at: start.addingTimeInterval(3_050)).count == 1, "next reset cycle can alert")

        var late = NodeDetector()
        expect(late.ingest(snapshot(50, resetAfter: 300), rules: [soon], at: start).isEmpty, "initial already-soon timestamp does not alert")
        expect(late.ingest(snapshot(50, resetAfter: 300), rules: [soon], at: start.addingTimeInterval(30)).isEmpty, "already-soon baseline stays quiet")
        _ = late.ingest(snapshot(50, resetAfter: 1_800), rules: [soon], at: start.addingTimeInterval(60))
        expect(late.ingest(snapshot(50, resetAfter: 1_800), rules: [soon], at: start.addingTimeInterval(1_900)).isEmpty, "missing the entire lead interval cannot announce recovery or send late warning")
        var revised = NodeDetector()
        _ = revised.ingest(snapshot(50), rules: [soon], at: start)
        expect(revised.ingest(snapshot(50, resetAfter: 500), rules: [soon], at: start.addingTimeInterval(60)).isEmpty, "backend moving reset directly into range does not replay a new timestamp")

        var missingReset = NodeDetector()
        _ = missingReset.ingest(snapshot(50), rules: [soon], at: start)
        expect(missingReset.ingest(snapshot(50, resetAfter: nil), rules: [soon], at: start.addingTimeInterval(1_100)).isEmpty, "unknown reset is not an event")
        expect(missingReset.ingest(snapshot(50), rules: [soon], at: start.addingTimeInterval(1_250)).count == 1, "temporarily absent reset timestamp preserves valid observation")

        var alarm = ReminderRule.make(kind: .scheduled)
        alarm.scheduledAt = start.addingTimeInterval(120)
        var scheduled = NodeDetector()
        expect(scheduled.ingest(nil, rules: [alarm], at: start).isEmpty, "scheduled reminder arms in future without network")
        expect(scheduled.ingest(nil, rules: [alarm], at: start.addingTimeInterval(119)).isEmpty, "scheduled reminder cannot fire early")
        let ringing = scheduled.ingest(nil, rules: [alarm], at: start.addingTimeInterval(120))
        expect(ringing.count == 1 && ringing[0].body.contains("设定时间"), "scheduled reminder fires at due tick while offline")
        expect(scheduled.ingest(nil, rules: [alarm], at: start.addingTimeInterval(130)).isEmpty, "scheduled reminder fires once")
        var savedAlarm = try JSONDecoder().decode(NodeDetector.self, from: JSONEncoder().encode(scheduled))
        expect(savedAlarm.ingest(nil, rules: [alarm], at: start.addingTimeInterval(150)).isEmpty, "scheduled deduplication survives restart")
        var newPast = NodeDetector()
        expect(newPast.ingest(nil, rules: [alarm], at: start.addingTimeInterval(200)).isEmpty, "adding past alarm does not backfill")
        alarm.enabled = false
        _ = newPast.ingest(nil, rules: [alarm], at: start.addingTimeInterval(210))
        alarm.enabled = true
        expect(newPast.ingest(nil, rules: [alarm], at: start.addingTimeInterval(220)).isEmpty, "enabling past alarm does not backfill")
        alarm.scheduledAt = start.addingTimeInterval(500)
        _ = newPast.ingest(nil, rules: [alarm], at: start.addingTimeInterval(250))
        expect(newPast.ingest(snapshot(20, account: "different-account"), rules: [alarm], at: start.addingTimeInterval(500)).count == 1, "account switch does not disrupt scheduled alarm")

        var sleeping = NodeDetector()
        alarm.scheduledAt = start.addingTimeInterval(600)
        _ = sleeping.ingest(nil, rules: [alarm], at: start.addingTimeInterval(500))
        var awakened = try JSONDecoder().decode(NodeDetector.self, from: JSONEncoder().encode(sleeping))
        expect(awakened.ingest(nil, rules: [alarm], at: start.addingTimeInterval(900)).count == 1, "previously armed alarm fires after sleep or restart")

        var ignored = NodeDetector()
        let tasks = ReminderRule.presets.filter { [.taskCompleted, .taskFailed, .taskNeedsInput].contains($0.kind) }
        expect(ignored.ingest(snapshot(0), rules: tasks, at: start).isEmpty, "task events are left to actual task signal matcher")
        _ = ignored.ingest(snapshot(50), rules: [low], at: start)
        _ = ignored.ingest(snapshot(30), rules: [], at: start.addingTimeInterval(30))
        expect(ignored.ingest(snapshot(5), rules: [low], at: start.addingTimeInterval(60)).isEmpty, "deleted and re-added rule gets new baseline")

        let roundTrip = try JSONDecoder().decode([ReminderRule].self, from: JSONEncoder().encode(ReminderRule.presets))
        expect(roundTrip == ReminderRule.presets, "rule presets round-trip exactly")
        print("PASS: \(checks) reminder rule and detector checks")
    }
}
