import SwiftUI

enum ReminderSettingsError: LocalizedError {
    case unreadableArchive, tooManyRules, invalidThreshold, invalidLeadTime, pastDate, longMessage

    var errorDescription: String? {
        switch self {
        case .unreadableArchive: return "已有规则记录无法读取，原记录已保留，暂时不能覆盖保存。"
        case .tooManyRules: return "最多保存 30 条规则，请先删除不再使用的规则。"
        case .invalidThreshold: return "剩余额度阈值应在 0% 到 100% 之间。"
        case .invalidLeadTime: return "提前提醒时间应在 1 到 10080 分钟之间。"
        case .pastDate: return "新提醒或修改后的提醒时间必须晚于现在。"
        case .longMessage: return "标题最多 100 字，正文最多 500 字；过多表情请适当减少。"
        }
    }
}

@MainActor final class ReminderStore: ObservableObject {
    @Published private(set) var rules: [ReminderRule]
    @Published private(set) var loadError: String?
    @Published private(set) var operationError: String?
    private let defaults: UserDefaults
    private static let storageKey = "nodeReminderRules"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.storageKey) != nil {
            if let data = defaults.data(forKey: Self.storageKey),
               let saved = try? JSONDecoder().decode([ReminderRule].self, from: data),
               saved.count <= 30, Set(saved.map(\.id)).count == saved.count {
                rules = saved
            } else {
                rules = []
                loadError = ReminderSettingsError.unreadableArchive.localizedDescription
            }
        } else {
            rules = ReminderRule.presets
        }
    }

    func save(_ input: ReminderRule) throws {
        guard loadError == nil else { throw ReminderSettingsError.unreadableArchive }
        var rule = input
        let previous = rules.first { $0.id == rule.id }
        guard previous != nil || rules.count < 30 else { throw ReminderSettingsError.tooManyRules }
        if rule.kind == .quotaBelow, !(0...100).contains(rule.threshold) {
            throw ReminderSettingsError.invalidThreshold
        }
        if rule.kind == .resetSoon, !(1...10080).contains(rule.minutesBeforeReset) {
            throw ReminderSettingsError.invalidLeadTime
        }
        if rule.kind == .scheduled,
           previous?.kind != .scheduled || previous?.scheduledAt != rule.scheduledAt,
           rule.scheduledAt <= Date() {
            throw ReminderSettingsError.pastDate
        }
        let fallback = ReminderRule.make(kind: rule.kind)
        rule.title = rule.title.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.body = rule.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.title.isEmpty { rule.title = fallback.title }
        if rule.body.isEmpty { rule.body = fallback.body }
        guard rule.title.count <= 100, rule.body.count <= 500,
              rule.title.utf8.count + rule.body.utf8.count <= 2500 else {
            throw ReminderSettingsError.longMessage
        }
        var next = rules
        if let index = next.firstIndex(where: { $0.id == rule.id }) { next[index] = rule }
        else { next.append(rule) }
        try persist(next)
    }

    func remove(id: String) {
        do { try persist(rules.filter { $0.id != id }) }
        catch { operationError = error.localizedDescription }
    }

    func setEnabled(id: String, enabled: Bool) {
        guard var rule = rules.first(where: { $0.id == id }) else { return }
        rule.enabled = enabled
        do { try save(rule) }
        catch { operationError = error.localizedDescription }
    }

    private func persist(_ next: [ReminderRule]) throws {
        guard loadError == nil else { throw ReminderSettingsError.unreadableArchive }
        let data = try JSONEncoder().encode(next)
        defaults.set(data, forKey: Self.storageKey)
        rules = next
        operationError = nil
    }
}

@MainActor struct ReminderSettingsView: View {
    @ObservedObject var store: ReminderStore
    @ObservedObject var phone: PhonePush
    let testRule: (ReminderRule) throws -> Void
    let openPhoneSettings: () -> Void
    let openContact: () -> Void
    let panelSize: CGSize
    @State private var selectedID: String?
    @State private var draft: ReminderRule?
    @State private var newKind: ReminderKind = .quotaBelow
    @State private var message: String?
    @State private var failed = false

    init(store: ReminderStore, phone: PhonePush, testRule: @escaping (ReminderRule) throws -> Void,
         openPhoneSettings: @escaping () -> Void, openContact: @escaping () -> Void = {},
         panelSize: CGSize = CGSize(width: 900, height: 720)) {
        self.store = store
        self.phone = phone
        self.testRule = testRule
        self.openPhoneSettings = openPhoneSettings
        self.openContact = openContact
        self.panelSize = panelSize
        _selectedID = State(initialValue: store.rules.first?.id)
        _draft = State(initialValue: store.rules.first)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    if let current = draft { editor(current) }
                    else {
                        VStack(spacing: 12) {
                            Image(systemName: "bell.badge").font(.largeTitle).foregroundStyle(AppStyle.accent)
                            Text("选择一条规则，或创建新的提醒。").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 80)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                actionBar
            }
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .background(AppStyle.background).tint(AppStyle.accent).preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge").font(.system(size: 20)).foregroundStyle(AppStyle.accent)
                    .frame(width: 38, height: 38)
                    .background(AppStyle.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text("关键节点提醒").font(.system(size: 17, weight: .semibold))
                    Text("\(store.rules.filter(\.enabled).count) 条已启用 · \(store.rules.count) / 30 条规则")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 10) {
                Picker("新建类型", selection: $newKind) {
                    ForEach(ReminderKind.allCases) { kind in Text(kind.title).tag(kind) }
                }.labelsHidden().accessibilityLabel("新建规则类型").frame(maxWidth: .infinity)
                Button {
                    draft = ReminderRule.make(kind: newKind)
                    selectedID = nil
                    message = nil
                } label: {
                    Label("新增规则", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(store.rules.count >= 30 || store.loadError != nil)
            }
            Divider()
            ScrollView {
                VStack(spacing: 9) {
                    ForEach(store.rules) { rule in
                        HStack(alignment: .center, spacing: 9) {
                            Button {
                                selectedID = rule.id
                                draft = rule
                                message = nil
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(rule.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    Text(condition(rule)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Toggle("启用 \(rule.title)", isOn: Binding(get: { rule.enabled }, set: { enabled in
                                store.setEnabled(id: rule.id, enabled: enabled)
                                if draft?.id == rule.id { draft?.enabled = enabled }
                            })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }
                        .padding(12)
                        .background(selectedID == rule.id ? AppStyle.accent.opacity(0.10) : Color.white.opacity(0.025),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selectedID == rule.id ? AppStyle.accent.opacity(0.22) : .clear))
                    }
                }
            }
            if let error = store.loadError ?? store.operationError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .padding(20).frame(width: 270).background(Color.black.opacity(0.12))
    }

    private func editor(_ current: ReminderRule) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeader(title: selectedID == nil ? "创建提醒规则" : "编辑提醒规则",
                           subtitle: "设置触发条件、提醒文案和通知渠道。", icon: "slider.horizontal.3")
            SettingsCard(title: "触发条件", icon: "bolt") {
                HStack {
                    Picker("节点类型", selection: binding(\.kind, current.kind)) {
                        ForEach(ReminderKind.allCases) { kind in Text(kind.title).tag(kind) }
                    }
                    Spacer()
                    Toggle("启用规则", isOn: binding(\.enabled, current.enabled)).toggleStyle(.switch).controlSize(.small)
                }
                switch current.kind {
                case .quotaBelow:
                    HStack {
                        Text("剩余额度降至")
                        TextField("百分比", value: binding(\.threshold, current.threshold), format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 65).accessibilityLabel("剩余额度阈值")
                        Text("% 时提醒")
                    }
                    hint("从阈值上方降到阈值或以下时提醒，不会每次检查重复通知。")
                case .resetSoon:
                    HStack {
                        Text("预计重置前")
                        TextField("分钟", value: binding(\.minutesBeforeReset, current.minutesBeforeReset), format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 65).accessibilityLabel("重置前提醒分钟")
                        Text("分钟提醒")
                    }
                    hint("预计时间仅供参考；额度实际恢复时仍由原有监测提醒。")
                case .scheduled:
                    DatePicker("提醒时间", selection: binding(\.scheduledAt, current.scheduledAt), displayedComponents: [.date, .hourAndMinute])
                    hint("指定时间只提醒一次。修改时间后可安排下一次提醒。")
                case .taskCompleted, .taskFailed, .taskNeedsInput:
                    hint("仅监测这台 Mac 上的新任务事件，首次启动不补发历史事件。")
                    if current.kind == .taskFailed {
                        hint("内部步骤错误经常会由 Codex 自动重试，因此默认关闭。它不代表整个任务失败。")
                    } else if current.kind == .taskNeedsInput {
                        hint("提醒表示有新的提问事件可查看，问题可能已被随后回答。系统权限审批弹窗暂不覆盖。")
                    }
                }
            }
            SettingsCard(title: "提醒文案", icon: "text.bubble") {
                Text("标题").foregroundStyle(.secondary)
                TextField("提醒标题", text: binding(\.title, current.title)).textFieldStyle(.roundedBorder)
                    .controlSize(.large).accessibilityLabel("节点提醒标题")
                Text("正文").foregroundStyle(.secondary)
                TextEditor(text: binding(\.body, current.body)).font(.system(size: 13))
                    .scrollContentBackground(.hidden).padding(8).frame(height: 100)
                    .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.09)))
                    .accessibilityLabel("节点提醒正文")
                hint("标题最多 100 字，正文最多 500 字。留空使用该类型的默认文案。")
            }
            SettingsCard(title: "通知渠道", icon: "paperplane") {
                HStack(spacing: 24) {
                    Toggle(isOn: binding(\.sound, current.sound)) { Label("声音", systemImage: "speaker.wave.2") }
                    Toggle(isOn: binding(\.popup, current.popup)) { Label("弹窗", systemImage: "macwindow") }
                    Toggle(isOn: binding(\.phone, current.phone)) { Label("手机", systemImage: "iphone") }
                }
                hint("勾选并保存后，等节点触发时提醒。「测试当前规则」会立即测试所选渠道。")
                if current.phone {
                    Divider()
                    HStack(alignment: .top, spacing: 8) {
                        if phone.isSending { ProgressView().controlSize(.small) }
                        else { Image(systemName: "iphone.radiowaves.left.and.right").foregroundStyle(AppStyle.accent) }
                        Text(phone.enabled ? phone.status : "手机推送总开关已关闭，本条规则不会发到手机。")
                            .foregroundStyle(phone.enabled ? Color.secondary : .orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    Button("iPhone 推送设置…", action: openPhoneSettings).buttonStyle(.bordered)
                }
            }
            hint("额度恢复提醒仍由主面板设置控制；本页用于新增关键节点。声音和手机推送的总开关仍然生效。")
        }.font(.system(size: 12)).padding(24)
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(failed ? Color.orange : AppStyle.accent) }
            HStack(spacing: 12) {
                Button("保存规则", action: save).buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(draft == nil || store.loadError != nil)
                Button(phone.isSending ? "发送中…" : "测试当前规则", action: test)
                    .buttonStyle(.bordered).controlSize(.large).disabled(draft == nil || phone.isSending)
                Spacer()
                if selectedID != nil {
                    Button("删除规则", role: .destructive) {
                        guard let selectedID else { return }
                        store.remove(id: selectedID)
                        self.selectedID = store.rules.first?.id
                        draft = store.rules.first
                        message = nil
                    }.buttonStyle(.borderless).disabled(store.loadError != nil)
                }
            }
            LicenseFooter(openContact: openContact)
        }.padding(.horizontal, 24).padding(.bottom, 16)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        guard let draft else { return }
        do {
            try store.save(draft)
            selectedID = draft.id
            self.draft = store.rules.first { $0.id == draft.id }
            message = "规则已保存。"
            failed = false
        } catch { message = error.localizedDescription; failed = true }
    }

    private func test() {
        guard let draft else { return }
        do {
            try testRule(draft)
            message = draft.phone ? "已触发测试；手机发送结果见通知渠道。" : "已按所选渠道触发测试。"
            failed = false
        } catch { message = error.localizedDescription; failed = true }
    }

    private func binding<Value>(_ path: WritableKeyPath<ReminderRule, Value>, _ fallback: Value) -> Binding<Value> {
        Binding(get: { draft?[keyPath: path] ?? fallback }, set: { draft?[keyPath: path] = $0 })
    }

    private func condition(_ rule: ReminderRule) -> String {
        switch rule.kind {
        case .quotaBelow: return "剩余 ≤ \(rule.threshold)%"
        case .resetSoon: return "预计重置前 \(rule.minutesBeforeReset) 分钟"
        case .scheduled: return rule.scheduledAt.formatted(date: .abbreviated, time: .shortened)
        case .taskCompleted, .taskFailed, .taskNeedsInput: return rule.kind.title
        }
    }
}
