import Foundation

// Compile with the declarations before Monitor in App.swift, extracted into a
// temporary file. This exercises SavedState without initializing UI or keychain.
@main struct NodeIntegrationTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError("FAIL: \(message)") }
    }

    static func snapshot(remaining: Double, resetAt: Date) -> UsageSnapshot {
        let window = QuotaWindow(usedPercent: 100 - remaining, windowDurationMins: 10080,
                                 resetsAt: Int(resetAt.timeIntervalSince1970))
        let bucket = QuotaBucket(limitId: "codex", limitName: nil, normalModelSlug: nil,
                                 primary: window, secondary: nil, credits: nil, spendControlReached: nil,
                                 planType: "pro", rateLimitReachedType: nil)
        return UsageSnapshot(ordinaryUsageAllowed: true, rateLimits: bucket,
                             rateLimitsByLimitId: nil, accountId: "test-account")
    }

    static func main() throws {
        struct LegacySavedState: Encodable {
            let detector: ResetDetector
            let snapshot: UsageSnapshot?
            let lastSuccess: Date?
            let history: [HistoryItem]
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let original = snapshot(remaining: 25, resetAt: now.addingTimeInterval(1800))
        let legacy = LegacySavedState(detector: ResetDetector(), snapshot: original,
                                      lastSuccess: now, history: [HistoryItem(id: "old", date: now, title: "历史提醒", body: "旧内容")])
        let restored = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(legacy))
        check(restored.nodeDetector == nil, "old state decodes without new detector field")
        check(restored.history.first?.id == "old" && restored.snapshot?.windows.first?.remainingPercent == 25,
              "migration preserves quota and history")

        var quota = ReminderRule.make(kind: .quotaBelow)
        quota.threshold = 20
        quota.title = "自定义额度提醒"
        quota.sound = false
        quota.popup = false
        quota.phone = true
        var scheduled = ReminderRule.make(kind: .scheduled)
        scheduled.scheduledAt = now.addingTimeInterval(60)
        scheduled.title = "自定义时间提醒"
        scheduled.sound = true
        scheduled.popup = true
        scheduled.phone = false
        var expected = ReminderRule.make(kind: .resetSoon)
        expected.minutesBeforeReset = 29
        expected.title = "自定义预计提醒"
        let rules = [quota, scheduled, expected]
        var detector = NodeDetector()
        check(detector.ingest(original, rules: rules, at: now).isEmpty, "initial snapshot sets baseline")
        let events = detector.ingest(snapshot(remaining: 19, resetAt: now.addingTimeInterval(1800)),
                                     rules: rules, at: now.addingTimeInterval(60))
        check(events.count == 3, "same tick keeps quota scheduled and expected-time events")
        let quotaEvent = events.first { $0.ruleID == quota.id }!
        let scheduledEvent = events.first { $0.ruleID == scheduled.id }!
        check(!quotaEvent.sound && !quotaEvent.popup && quotaEvent.phone, "quota event keeps phone-only routing")
        check(scheduledEvent.sound && scheduledEvent.popup && !scheduledEvent.phone, "scheduled event keeps local-only routing")
        let request = try BarkRequest.make(deviceKey: "FakeKeyOnly", test: false,
                                           title: quotaEvent.title, body: quotaEvent.body)
        let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        check(payload["title"] == quota.title && payload["body"]?.contains("19%") == true,
              "custom node text and actual detail reach the phone request")
        check(payload["title"] != BarkMessage.defaultTitle, "node request is not replaced with recovery wording")
        let saved = SavedState(detector: restored.detector, snapshot: original, lastSuccess: now,
                               history: restored.history, nodeDetector: detector)
        var resumed = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(saved)).nodeDetector!
        check(resumed.ingest(snapshot(remaining: 19, resetAt: now.addingTimeInterval(1800)),
                             rules: rules, at: now.addingTimeInterval(75)).isEmpty,
              "persisted state does not repeat any already-fired node after restart")
        var edited = quota
        edited.threshold = 30
        check(resumed.ingest(snapshot(remaining: 19, resetAt: now.addingTimeInterval(1800)),
                             rules: [edited], at: now.addingTimeInterval(90)).isEmpty,
              "editing threshold creates a new baseline rather than historical alert")
        print("PASS: \(checks) node integration checks (no network, UI, real defaults, or keychain)")
    }
}
