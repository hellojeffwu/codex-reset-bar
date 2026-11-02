import Foundation

struct QuotaWindow: Codable, Equatable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int?
}

struct QuotaCredits: Codable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?
}

struct QuotaBucket: Codable {
    let limitId: String?
    let limitName: String?
    let normalModelSlug: String?
    let primary: QuotaWindow?
    let secondary: QuotaWindow?
    let credits: QuotaCredits?
    let spendControlReached: Bool?
    let planType: String?
    let rateLimitReachedType: String?
}

struct DisplayWindow: Identifiable {
    let id: String
    let title: String
    let usedPercent: Double
    let durationMins: Int?
    let resetsAtDate: Date?

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

struct UsageSnapshot: Codable {
    let ordinaryUsageAllowed: Bool?
    let rateLimits: QuotaBucket
    let rateLimitsByLimitId: [String: QuotaBucket]?
    let accountId: String?

    private var buckets: [(String, QuotaBucket)] {
        if let values = rateLimitsByLimitId, !values.isEmpty {
            return values.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }
        return [(rateLimits.limitId ?? "codex", rateLimits)]
    }

    var planName: String {
        let plan = rateLimits.planType ?? buckets.compactMap { $0.1.planType }.first
        guard let plan, !plan.isEmpty else { return "套餐未知" }
        return plan.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var windows: [DisplayWindow] {
        buckets.flatMap { key, bucket in
            [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { slot, value in
                guard let value else { return nil }
                let name = bucket.limitName ?? (key == "codex" ? "Codex" : key)
                let duration: String
                switch value.windowDurationMins {
                case 10_080: duration = "每周额度"
                case 1_440: duration = "每日额度"
                case let mins? where mins > 0 && mins % 60 == 0: duration = "\(mins / 60) 小时额度"
                case let mins? where mins > 0: duration = "\(mins) 分钟额度"
                default: duration = slot == "primary" ? "主额度" : "次额度"
                }
                return DisplayWindow(
                    id: "\(key)/\(slot)", title: "\(name) · \(duration)",
                    usedPercent: value.usedPercent, durationMins: value.windowDurationMins,
                    resetsAtDate: value.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                )
            }
        }
    }
}

struct RecoveryEvent: Identifiable, Codable {
    let id: String
    let title: String
    let body: String
}

struct ResetDetector: Codable {
    private var accountId: String?
    private var lastPermission: Bool?
    private var checkpoints: [String: Checkpoint] = [:]
    private var lastEventFingerprint: String?
    private var lastEventAt: Date?
    private(set) var lastGoodSnapshot: UsageSnapshot?
    private(set) var lastObservedAt: Date?

    private struct Checkpoint: Codable {
        let usedPercent: Double
        let durationMins: Int?
    }

    mutating func ingest(_ snapshot: UsageSnapshot, at date: Date) -> [RecoveryEvent] {
        guard let currentAccount = snapshot.accountId, !currentAccount.isEmpty else {
            self = ResetDetector()
            return []
        }
        if accountId != currentAccount {
            self = ResetDetector()
            accountId = currentAccount
            record(snapshot, at: date)
            return []
        }
        // Missing permission is not a recovery. Keep the last explicit state so
        // a temporary unknown response cannot hide a later false → true event.
        guard let allowed = snapshot.ordinaryUsageAllowed else { return [] }

        let permissionRecovered = lastPermission == false && allowed
        let restored = snapshot.windows.filter { window in
            guard let previous = checkpoints[window.id],
                  previous.durationMins == window.durationMins else { return false }
            let previousRemaining = max(0, min(100, 100 - previous.usedPercent))
            return window.remainingPercent - previousRemaining >= 1
        }
        let details = restored.map { window in
            let previous = checkpoints[window.id]!
            let oldRemaining = max(0, min(100, 100 - previous.usedPercent))
            return "\(window.title)：剩余 \(Self.percent(oldRemaining)) → \(Self.percent(window.remainingPercent))"
        }
        record(snapshot, at: date)
        guard allowed && (permissionRecovered || !restored.isEmpty) else { return [] }

        let body = details.isEmpty ? "Codex 已确认普通额度恢复可用。" : details.joined(separator: "\n")
        let resetTimes = restored.map { "\($0.id):\($0.resetsAtDate?.timeIntervalSince1970 ?? 0)" }.joined(separator: "|")
        let fingerprint = "\(permissionRecovered)|\(body)|\(resetTimes)"
        if !permissionRecovered, fingerprint == lastEventFingerprint, let previousDate = lastEventAt,
           date.timeIntervalSince(previousDate) >= 0,
           date.timeIntervalSince(previousDate) < 300 { return [] }
        lastEventFingerprint = fingerprint
        lastEventAt = date
        return [RecoveryEvent(id: UUID().uuidString, title: "Codex 额度已恢复", body: body)]
    }

    private mutating func record(_ snapshot: UsageSnapshot, at date: Date) {
        guard let permission = snapshot.ordinaryUsageAllowed else { return }
        lastPermission = permission
        for window in snapshot.windows {
            checkpoints[window.id] = Checkpoint(usedPercent: window.usedPercent, durationMins: window.durationMins)
        }
        lastGoodSnapshot = snapshot
        lastObservedAt = date
    }

    private static func percent(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))%" : String(format: "%.1f%%", value)
    }
}
