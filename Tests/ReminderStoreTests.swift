import Foundation

@main struct ReminderStoreTests {
    @MainActor static func main() throws {
        let suite = "CodexReminderStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
            checks += 1
            if !condition() { fatalError("FAIL: \(description)") }
        }
        func rejects(_ description: String, _ action: () throws -> Void) {
            checks += 1
            do { try action(); fatalError("FAIL: \(description)") } catch { }
        }
        let first = ReminderStore(defaults: defaults)
        expect(first.rules.count == ReminderRule.presets.count, "first launch offers presets")
        expect(defaults.object(forKey: "nodeReminderRules") == nil, "initialization does not overwrite preferences")

        defaults.set(try JSONEncoder().encode([ReminderRule]()), forKey: "nodeReminderRules")
        let store = ReminderStore(defaults: defaults)
        var quota = ReminderRule.make(kind: .quotaBelow)
        quota.threshold = -1
        rejects("negative threshold rejected") { try store.save(quota) }
        quota.threshold = 101
        rejects("threshold above 100 rejected") { try store.save(quota) }
        quota.threshold = 20
        quota.title = "  提醒我  "
        quota.body = "  第一行\n第二行 🛎️  "
        try store.save(quota)
        expect(store.rules[0].title == "提醒我" && store.rules[0].body == "第一行\n第二行 🛎️", "text is trimmed without losing internal newlines")
        quota.title = "   "
        quota.body = "\n"
        try store.save(quota)
        expect(!store.rules[0].title.isEmpty && !store.rules[0].body.isEmpty, "blank text falls back to kind defaults")
        quota.title = String(repeating: "长", count: 101)
        rejects("long title rejected") { try store.save(quota) }
        quota.title = "标题"
        quota.body = String(repeating: "长", count: 501)
        rejects("long body rejected") { try store.save(quota) }

        var lead = ReminderRule.make(kind: .resetSoon)
        lead.minutesBeforeReset = 0
        rejects("zero lead time rejected") { try store.save(lead) }
        lead.minutesBeforeReset = 10081
        rejects("excessive lead time rejected") { try store.save(lead) }

        var scheduled = ReminderRule.make(kind: .scheduled)
        scheduled.scheduledAt = Date().addingTimeInterval(-60)
        rejects("new past schedule rejected") { try store.save(scheduled) }
        scheduled.scheduledAt = Date().addingTimeInterval(3600)
        try store.save(scheduled)
        expect(ReminderStore(defaults: defaults).rules.contains(where: { $0.id == scheduled.id }), "saved schedule survives reload")
        scheduled.scheduledAt = Date().addingTimeInterval(-1)
        rejects("changed date cannot be in past") { try store.save(scheduled) }

        store.setEnabled(id: quota.id, enabled: false)
        expect(ReminderStore(defaults: defaults).rules.first(where: { $0.id == quota.id })?.enabled == false, "enabled toggle is persisted")
        store.remove(id: quota.id)
        expect(!ReminderStore(defaults: defaults).rules.contains(where: { $0.id == quota.id }), "deletion is persisted")

        var expired = ReminderRule.make(kind: .scheduled)
        expired.scheduledAt = Date().addingTimeInterval(-60)
        defaults.set(try JSONEncoder().encode([expired]), forKey: "nodeReminderRules")
        let expiredStore = ReminderStore(defaults: defaults)
        expired.title = "只改文案"
        try expiredStore.save(expired)
        expect(expiredStore.rules[0].title == "只改文案", "expired rule may edit wording without rescheduling")

        defaults.set(try JSONEncoder().encode([ReminderRule]()), forKey: "nodeReminderRules")
        let capped = ReminderStore(defaults: defaults)
        for _ in 0..<30 { try capped.save(ReminderRule.make(kind: .taskCompleted)) }
        rejects("31st rule rejected") { try capped.save(ReminderRule.make(kind: .taskFailed)) }
        var existing = capped.rules[0]
        existing.title = "仍可编辑"
        try capped.save(existing)
        expect(capped.rules.count == 30 && capped.rules[0].title == "仍可编辑", "existing rule editable at limit")

        let broken = Data("broken archive".utf8)
        defaults.set(broken, forKey: "nodeReminderRules")
        let corrupt = ReminderStore(defaults: defaults)
        expect(corrupt.loadError != nil && corrupt.rules.isEmpty, "corrupt archive is reported")
        rejects("corrupt archive cannot be overwritten by save") { try corrupt.save(ReminderRule.make(kind: .quotaBelow)) }
        corrupt.remove(id: "none")
        expect(defaults.data(forKey: "nodeReminderRules") == broken, "corrupt bytes retained after mutation attempts")
        defaults.set("wrong type", forKey: "nodeReminderRules")
        expect(ReminderStore(defaults: defaults).loadError != nil, "non-data archive is protected")
        print("PASS: \(checks) reminder-store checks (isolated preferences only)")
    }
}
