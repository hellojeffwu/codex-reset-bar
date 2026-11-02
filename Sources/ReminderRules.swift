import Foundation

enum ReminderKind: String, Codable, CaseIterable, Identifiable {
    case quotaBelow, resetSoon, scheduled, taskCompleted, taskFailed, taskNeedsInput

    var id: String { rawValue }
    var title: String {
        switch self {
        case .quotaBelow: return "剩余额度低于阈值"
        case .resetSoon: return "预计重置前提醒"
        case .scheduled: return "指定时间提醒"
        case .taskCompleted: return "本轮任务完成"
        case .taskFailed: return "执行步骤报错"
        case .taskNeedsInput: return "任务提问 / 待查看"
        }
    }
}

struct ReminderRule: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    var kind: ReminderKind
    var enabled = true
    var threshold = 20
    var minutesBeforeReset = 10
    var scheduledAt = Date().addingTimeInterval(3_600)
    var title: String
    var body: String
    var sound = true
    var popup = true
    var phone = true

    static func make(kind: ReminderKind) -> ReminderRule {
        let title: String
        let body: String
        switch kind {
        case .quotaBelow:
            title = "Codex 剩余额度偏低"
            body = "剩余额度已达到你设置的提醒阈值。"
        case .resetSoon:
            title = "Codex 接近预计重置时间"
            body = "这是预计时间提醒，额度是否恢复仍以实际检测为准。"
        case .scheduled:
            title = "Codex 定时提醒"
            body = "到你设置的提醒时间了。"
        case .taskCompleted:
            title = "Codex 这一轮已完成"
            body = "有一个 Codex 对话完成了这一轮工作，可以查看结果了。"
        case .taskFailed:
            title = "Codex 执行步骤报错"
            body = "有一个 Codex 执行步骤返回错误；这不代表整个任务失败。"
        case .taskNeedsInput:
            title = "Codex 任务有提问"
            body = "有一个 Codex 对话发出了需要你回答的问题，可以打开查看。"
        }
        return ReminderRule(kind: kind, title: title, body: body)
    }

    static let presets: [ReminderRule] = {
        var low20 = make(kind: .quotaBelow)
        low20.id = "preset.quota-below-20"
        var low10 = make(kind: .quotaBelow)
        low10.id = "preset.quota-below-10"
        low10.threshold = 10
        var reset = make(kind: .resetSoon)
        reset.id = "preset.reset-soon-10m"
        let tasks = [ReminderKind.taskCompleted, .taskFailed, .taskNeedsInput].map { kind in
            var rule = make(kind: kind)
            rule.id = "preset.\(kind.rawValue)"
            if kind == .taskFailed { rule.enabled = false }
            return rule
        }
        return ([low20, low10, reset] + tasks).map { rule in
            var stable = rule
            // Unused for these presets; keep their complete signatures stable.
            stable.scheduledAt = Date(timeIntervalSince1970: 0)
            return stable
        }
    }()
}

struct NodeReminder: Identifiable {
    let id: String
    let ruleID: String
    let title: String
    let body: String
    let sound: Bool
    let popup: Bool
    let phone: Bool
}

struct NodeDetector: Codable {
    private var accountID: String?
    private var states: [String: RuleState] = [:]

    private struct RuleState: Codable {
        let rule: ReminderRule
        var windows: [String: WindowState] = [:]
        var scheduledPending: Bool
    }

    private struct WindowState: Codable {
        var remaining: Double
        var duration: Int?
        var armed: Bool
        var resetAt: Date?
        var observedAt: Date
        var notifiedResets: [Date] = []
    }

    mutating func ingest(_ snapshot: UsageSnapshot?, rules: [ReminderRule], at now: Date) -> [NodeReminder] {
        let ruleIDs = Set(rules.map(\.id))
        states = states.filter { ruleIDs.contains($0.key) }
        if let snapshot {
            let identity = snapshot.accountId.flatMap { $0.isEmpty ? nil : $0 }
            if identity != accountID {
                accountID = identity
                for id in Array(states.keys) { states[id]?.windows.removeAll() }
            }
        }

        var events: [NodeReminder] = []
        for rule in rules {
            guard [.quotaBelow, .resetSoon, .scheduled].contains(rule.kind) else {
                states.removeValue(forKey: rule.id)
                continue
            }
            var state = states[rule.id]
            if state?.rule != rule {
                state = RuleState(rule: rule, scheduledPending: rule.enabled && rule.scheduledAt > now)
            }
            var current = state!
            defer { states[rule.id] = current }
            guard rule.enabled else { continue }

            if rule.kind == .scheduled {
                if current.scheduledPending && now >= rule.scheduledAt {
                    current.scheduledPending = false
                    events.append(reminder(rule, details: ["设定时间：\(Self.dateText(rule.scheduledAt))"]))
                }
                continue
            }
            // Callers pass nil on clock ticks or failed reads. Cached snapshots
            // must never create a quota or expected-reset notification.
            guard let snapshot, accountID != nil else { continue }
            var details: [String] = []
            for window in snapshot.windows {
                if rule.kind == .resetSoon && window.resetsAtDate == nil { continue }
                let threshold = Double(max(0, min(100, rule.threshold)))
                let old = current.windows[window.id]
                var next = WindowState(remaining: window.remainingPercent, duration: window.durationMins,
                                       armed: window.remainingPercent > threshold,
                                       resetAt: window.resetsAtDate, observedAt: now)
                if let old, old.duration == window.durationMins {
                    next.armed = old.armed
                    next.notifiedResets = old.notifiedResets
                    if rule.kind == .quotaBelow {
                        if old.armed && old.remaining > threshold && window.remainingPercent <= threshold {
                            details.append("\(window.title)：剩余 \(Self.percent(window.remainingPercent))（提醒阈值 \(Int(threshold))%）")
                            next.armed = false
                        } else if window.remainingPercent >= threshold + 1 {
                            next.armed = true
                        }
                    } else if let resetAt = window.resetsAtDate, old.resetAt == resetAt {
                        let lead = Double(max(1, min(10_080, rule.minutesBeforeReset)) * 60)
                        let remaining = resetAt.timeIntervalSince(now)
                        if remaining > 0 && remaining <= lead && resetAt.timeIntervalSince(old.observedAt) > lead
                            && !old.notifiedResets.contains(resetAt) {
                            details.append("\(window.title)：预计 \(Self.dateText(resetAt)) 重置（约 \(Int(ceil(remaining / 60))) 分钟后）")
                            next.notifiedResets = Array((old.notifiedResets + [resetAt]).suffix(16))
                        }
                    }
                }
                current.windows[window.id] = next
            }
            if !details.isEmpty { events.append(reminder(rule, details: details)) }
        }
        return events
    }

    private func reminder(_ rule: ReminderRule, details: [String]) -> NodeReminder {
        let lines = ([rule.body] + details).filter { !$0.isEmpty }
        return NodeReminder(id: UUID().uuidString, ruleID: rule.id, title: rule.title,
                            body: lines.joined(separator: "\n"), sound: rule.sound, popup: rule.popup, phone: rule.phone)
    }

    private static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func percent(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))%" : String(format: "%.1f%%", value)
    }
}
