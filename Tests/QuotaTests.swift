import Foundation

@main
struct QuotaTests {
    static var checks = 0
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }

    static func bucket(_ used: Double?, minutes: Int? = 10_080, reset: Int? = 1_790_000_500,
                       secondary: Double? = nil) -> QuotaBucket {
        QuotaBucket(limitId: "codex", limitName: nil, normalModelSlug: nil,
                    primary: used.map { QuotaWindow(usedPercent: $0, windowDurationMins: minutes, resetsAt: reset) },
                    secondary: secondary.map { QuotaWindow(usedPercent: $0, windowDurationMins: 300, resetsAt: reset) },
                    credits: nil, spendControlReached: nil, planType: "pro", rateLimitReachedType: nil)
    }

    static func snapshot(_ used: Double?, allowed: Bool? = true, account: String? = "a",
                         minutes: Int? = 10_080, reset: Int? = 1_790_000_500,
                         secondary: Double? = nil, multiple: Bool = false) -> UsageSnapshot {
        let value = bucket(used, minutes: minutes, reset: reset, secondary: secondary)
        return UsageSnapshot(ordinaryUsageAllowed: allowed, rateLimits: value,
                             rateLimitsByLimitId: multiple ? ["codex": value, "other": bucket(used)] : nil,
                             accountId: account)
    }

    static func main() throws {
        var detector = ResetDetector()
        expect(detector.ingest(snapshot(60), at: start).isEmpty, "first read is a baseline")
        expect(detector.ingest(snapshot(65), at: start.addingTimeInterval(30)).isEmpty, "ordinary consumption is not recovery")
        let early = detector.ingest(snapshot(0), at: start.addingTimeInterval(60))
        expect(early.count == 1 && early[0].body.contains("35% → 100%"), "unscheduled recovery before reset time is detected")
        expect(detector.ingest(snapshot(0), at: start.addingTimeInterval(90)).isEmpty, "repeated snapshot does not repeat reminder")

        var persisted = try JSONDecoder().decode(ResetDetector.self, from: JSONEncoder().encode(detector))
        expect(persisted.ingest(snapshot(0), at: start.addingTimeInterval(120)).isEmpty, "restart preserves deduplication and baseline")
        expect(persisted.lastObservedAt == start.addingTimeInterval(120), "successful observed time is persisted")

        var blocked = ResetDetector()
        _ = blocked.ingest(snapshot(100, allowed: false), at: start)
        expect(blocked.ingest(snapshot(0, allowed: nil), at: start.addingTimeInterval(30)).isEmpty, "unknown permission cannot promise recovery")
        expect(blocked.ingest(snapshot(0), at: start.addingTimeInterval(60)).count == 1, "false unknown true retains recovery")

        var permissionOnly = ResetDetector()
        _ = permissionOnly.ingest(snapshot(nil, allowed: false), at: start)
        expect(permissionOnly.ingest(snapshot(nil), at: start.addingTimeInterval(30)).count == 1, "explicit permission recovery needs no percentage")
        _ = permissionOnly.ingest(snapshot(nil, allowed: false), at: start.addingTimeInterval(60))
        expect(permissionOnly.ingest(snapshot(nil), at: start.addingTimeInterval(90)).count == 1, "a separate explicit recovery is not suppressed by the noise filter")

        var denied = ResetDetector()
        _ = denied.ingest(snapshot(90, allowed: false), at: start)
        expect(denied.ingest(snapshot(0, allowed: false), at: start.addingTimeInterval(30)).isEmpty, "lower usage without permission cannot promise availability")

        var switched = ResetDetector()
        _ = switched.ingest(snapshot(100, allowed: false), at: start)
        expect(switched.ingest(snapshot(0, account: "b"), at: start.addingTimeInterval(30)).isEmpty, "account switch establishes fresh baseline")
        _ = switched.ingest(snapshot(80, account: "b"), at: start.addingTimeInterval(60))
        expect(switched.ingest(snapshot(0, account: nil), at: start.addingTimeInterval(90)).isEmpty, "unknown identity cannot compare accounts")
        expect(switched.ingest(snapshot(0, account: "b"), at: start.addingTimeInterval(120)).isEmpty, "identity returning establishes a new baseline")

        var missing = ResetDetector()
        _ = missing.ingest(snapshot(80), at: start)
        expect(missing.ingest(snapshot(nil), at: start.addingTimeInterval(30)).isEmpty, "missing window is not zero usage")
        expect(missing.ingest(snapshot(0), at: start.addingTimeInterval(60)).count == 1, "temporarily omitted window retains its known baseline")

        var noTimer = ResetDetector()
        _ = noTimer.ingest(snapshot(60), at: start)
        expect(noTimer.ingest(snapshot(60), at: start.addingTimeInterval(900)).isEmpty, "passing expected reset time alone never alerts")
        expect(noTimer.ingest(snapshot(60, reset: 1_790_009_000), at: start.addingTimeInterval(930)).isEmpty, "changed reset timestamp alone never alerts")

        var durations = ResetDetector()
        _ = durations.ingest(snapshot(80), at: start)
        expect(durations.ingest(snapshot(0, minutes: 300), at: start.addingTimeInterval(30)).isEmpty, "changed window duration is not comparable")

        var multi = ResetDetector()
        _ = multi.ingest(snapshot(90, secondary: 80, multiple: true), at: start)
        let merged = multi.ingest(snapshot(0, secondary: 0, multiple: true), at: start.addingTimeInterval(30))
        expect(merged.count == 1, "simultaneous bucket recoveries merge into one notification")
        expect(merged[0].body.components(separatedBy: "\n").count == 3, "merged reminder includes all recovered windows")

        var noise = ResetDetector()
        _ = noise.ingest(snapshot(50), at: start)
        expect(noise.ingest(snapshot(49.5), at: start.addingTimeInterval(30)).isEmpty, "fractional adjustment below one point is ignored")
        expect(noise.ingest(snapshot(48), at: start.addingTimeInterval(60)).count == 1, "real decrease is detected")
        _ = noise.ingest(snapshot(49.5), at: start.addingTimeInterval(90))
        expect(noise.ingest(snapshot(48), at: start.addingTimeInterval(120)).isEmpty, "identical short-lived oscillation is deduplicated")
        _ = noise.ingest(snapshot(49.5), at: start.addingTimeInterval(400))
        expect(noise.ingest(snapshot(48), at: start.addingTimeInterval(430)).count == 1, "later real recovery can notify again")

        let modernJSON = Data("""
        {"ordinaryUsageAllowed":true,"accountId":"sample","rateLimits":{"primary":{"usedPercent":17,"windowDurationMins":10080,"resetsAt":1793608297},"planType":"pro"},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":17,"windowDurationMins":10080,"resetsAt":1793608297},"planType":"pro"}},"futureField":true}
        """.utf8)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: modernJSON)
        expect(decoded.windows.count == 1 && decoded.windows[0].remainingPercent == 83, "decodes sparse backend response and avoids legacy duplication")
        expect(decoded.windows[0].title == "Codex · 每周额度", "primary is labeled by actual duration, not assumed five hours")
        expect(decoded.planName == "Pro", "plan display reads backend")
        expect(snapshot(125).windows[0].remainingPercent == 0, "remaining display is clamped")
        var overage = ResetDetector()
        _ = overage.ingest(snapshot(125), at: start)
        expect(overage.ingest(snapshot(120), at: start.addingTimeInterval(30)).isEmpty, "falling overage without any available percentage is not recovered quota")
        expect(snapshot(5, minutes: nil, reset: nil).windows[0].resetsAtDate == nil, "unknown reset time remains unknown")
        print("PASS: \(checks) quota model and recovery checks")
    }
}
