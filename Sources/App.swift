import AppKit
import SwiftUI
import Combine

private let appID = "local.benxin.codex-reset-bar"
private let appName = "Codex 额度提醒"

struct HistoryItem: Codable, Identifiable {
    let id: String
    let date: Date
    let title: String
    let body: String
}

struct SavedState: Codable {
    var detector: ResetDetector
    var snapshot: UsageSnapshot?
    var lastSuccess: Date?
    var history: [HistoryItem]
    var nodeDetector: NodeDetector?
}

@MainActor final class Monitor: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var lastSuccess: Date?
    @Published var error: String?
    @Published var refreshing = false
    @Published var history: [HistoryItem] = []
    @Published var alertPending = false
    @Published var sound = UserDefaults.standard.object(forKey: "sound") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(sound, forKey: "sound")
            if sound && pendingSound { alarm.start() } else { alarm.stop() }
        }
    }
    @Published var popup = UserDefaults.standard.object(forKey: "popup") as? Bool ?? true {
        didSet { UserDefaults.standard.set(popup, forKey: "popup") }
    }
    @Published var login = FileManager.default.fileExists(atPath: loginURL.path)
    var updated: (() -> Void)?
    var presentAlert: ((String, String, Bool) -> Void)?
    let phone = PhonePush()
    let reminders = ReminderStore()
    private let alarm = RepeatingAlarm()
    private var detector = ResetDetector()
    private var nodeDetector = NodeDetector()
    private let taskActivity = TaskActivityMonitor()
    private var scanningTasks = false
    private var nodeTimer: Timer?
    private var rulesSubscription: AnyCancellable?
    private var taskRuleStarts: [String: Date] = [:]
    private var knownRules: [ReminderRule] = []
    private var pendingSound = false
    private var pendingMessages: [(String, String)] = []
    private var timer: Timer?
    private let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexResetBar", isDirectory: true)
    private var stateURL: URL { directory.appendingPathComponent("state.json") }

    init() {
        if let data = try? Data(contentsOf: stateURL),
           let saved = try? JSONDecoder().decode(SavedState.self, from: data) {
            detector = saved.detector
            snapshot = saved.snapshot
            lastSuccess = saved.lastSuccess
            history = saved.history
            nodeDetector = saved.nodeDetector ?? NodeDetector()
        }
        knownRules = reminders.rules
        taskRuleStarts = Dictionary(uniqueKeysWithValues: knownRules.map { ($0.id, Date()) })
        rulesSubscription = reminders.$rules.dropFirst().sink { [weak self] rules in
            guard let self else { return }
            let now = Date()
            for rule in rules where !self.knownRules.contains(rule) { self.taskRuleStarts[rule.id] = now }
            self.knownRules = rules
            let events = self.nodeDetector.ingest(nil, rules: rules, at: now)
            self.deliverNodes(events)
            self.save()
        }
    }

    var statusText: String {
        if error != nil { return "连接中断 · 将自动重试" }
        if refreshing && lastSuccess == nil { return "正在连接本机 Codex…" }
        switch snapshot?.ordinaryUsageAllowed {
        case true: return "正在监测 · 普通额度可用"
        case false: return "正在监测 · 等待额度恢复"
        default: return "正在监测 · 可用状态未提供"
        }
    }

    func start() {
        relocateExistingLoginItem()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        let ticks = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkNodes() }
        }
        RunLoop.main.add(ticks, forMode: .common)
        nodeTimer = ticks
        checkNodes()
    }

    @objc private func woke() { refresh(); checkNodes() }

    private func checkNodes() {
        deliverNodes(nodeDetector.ingest(nil, rules: reminders.rules, at: Date()))
        save()
        guard !scanningTasks else { return }
        scanningTasks = true
        Task {
            let signals = await taskActivity.poll()
            let events = signals.flatMap { signal -> [NodeReminder] in
                let kind: ReminderKind
                switch signal.kind {
                case .completed: kind = .taskCompleted
                case .failed: kind = .taskFailed
                case .needsInput: kind = .taskNeedsInput
                }
                return reminders.rules.filter {
                    $0.enabled && $0.kind == kind && signal.date >= (taskRuleStarts[$0.id] ?? .distantPast)
                }.map { rule in
                    NodeReminder(id: "\(signal.id):\(rule.id)", ruleID: rule.id, title: rule.title,
                                 body: "\(rule.body)\n\(signal.detail)", sound: rule.sound, popup: rule.popup, phone: rule.phone)
                }
            }
            deliverNodes(events)
            if !events.isEmpty { save() }
            scanningTasks = false
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            do {
                let data = try await CodexBridge.fetch()
                let current = try JSONDecoder().decode(UsageSnapshot.self, from: data)
                let now = Date()
                let events = detector.ingest(current, at: now)
                let nodes = nodeDetector.ingest(current, rules: reminders.rules, at: now)
                snapshot = current
                lastSuccess = now
                error = nil
                for event in events {
                    history.insert(HistoryItem(id: event.id, date: now, title: event.title, body: event.body), at: 0)
                }
                history = Array(history.prefix(8))
                save()
                if let event = events.first { notify(title: event.title, body: event.body, test: false) }
                deliverNodes(nodes)
                if !nodes.isEmpty { save() }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "读取额度失败，将在下次检查时重试。"
            }
            refreshing = false
            updated?()
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let state = SavedState(detector: detector, snapshot: snapshot, lastSuccess: lastSuccess,
                                   history: history, nodeDetector: nodeDetector)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        } catch {
            self.error = "额度已读到，但本地记录保存失败；重启后可能重复提醒。"
        }
    }

    func testAlert() {
        notify(title: "这是一条测试提醒", body: "声音每 5 秒重复，直到你点击「知道了」或关闭弹窗。当前额度没有发生变化。", test: true)
    }

    private func notify(title: String, body: String, test: Bool,
                        useSound: Bool = true, usePopup: Bool = true, usePhone: Bool = true,
                        message: BarkMessage? = nil, forcePopup: Bool = true) {
        let audible = sound && useSound
        let visible = (popup && usePopup) || (test && forcePopup)
        if audible || visible {
            alertPending = true
            pendingSound = pendingSound || useSound
            if audible { alarm.start() }
        }
        if visible {
            pendingMessages.append((title, body))
            pendingMessages = Array(pendingMessages.suffix(8))
            let combinedTitle = pendingMessages.count == 1 ? title : "Codex 有 \(pendingMessages.count) 条提醒"
            let combinedBody = pendingMessages.count == 1 ? body : pendingMessages.map { "\($0.0)\n\($0.1)" }.joined(separator: "\n\n")
            presentAlert?(combinedTitle, combinedBody, test)
        }
        if usePhone && (!test || message != nil) { Task { await phone.send(test: test, message: message) } }
        updated?()
    }

    private func deliverNodes(_ events: [NodeReminder], test: Bool = false) {
        guard !events.isEmpty else { return }
        if !test {
            for event in events {
                history.insert(HistoryItem(id: event.id, date: Date(), title: event.title, body: event.body), at: 0)
            }
            history = Array(history.prefix(8))
        }
        let visibleEvents = events.filter { $0.popup }
        let title = visibleEvents.count == 1 ? visibleEvents[0].title : "Codex 关键节点提醒（\(visibleEvents.count) 条）"
        let body = visibleEvents.map { visibleEvents.count == 1 ? $0.body : "\($0.title)\n\($0.body)" }.joined(separator: "\n\n")
        notify(title: test ? "【测试】\(title)" : title, body: body, test: test,
               useSound: events.contains { $0.sound }, usePopup: events.contains { $0.popup },
               usePhone: false, forcePopup: false)
        let phoneEvents = events.filter { $0.phone && phone.enabled }
        Task {
            for event in phoneEvents {
                var text = String(event.body.prefix(500))
                while !text.isEmpty && text.utf8.count + event.title.utf8.count > 2500 { text.removeLast() }
                if let message = try? BarkMessage(title: event.title, body: text) {
                    await phone.send(test: test, message: message)
                }
            }
        }
    }

    func testRule(_ rule: ReminderRule) throws {
        let fallback = ReminderRule.make(kind: rule.kind)
        let message = try BarkMessage(title: rule.title.isEmpty ? fallback.title : rule.title,
                                      body: rule.body.isEmpty ? fallback.body : rule.body)
        deliverNodes([NodeReminder(id: UUID().uuidString, ruleID: rule.id, title: message.title,
                                  body: message.body + "\n这是规则测试，没有发生实际节点变化。",
                                  sound: rule.sound, popup: rule.popup, phone: rule.phone)], test: true)
    }

    func acknowledge() {
        alarm.stop()
        alertPending = false
        pendingSound = false
        pendingMessages = []
        updated?()
    }

    static var loginURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(appID).plist")
    }

    private func relocateExistingLoginItem() {
        guard let executable = Bundle.main.executablePath,
              let data = try? Data(contentsOf: Self.loginURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let updated = LoginConfiguration.relocated(plist, label: appID, executable: executable) else { return }
        do {
            try PropertyListSerialization.data(fromPropertyList: updated, format: .xml, options: 0)
                .write(to: Self.loginURL, options: .atomic)
        } catch { self.error = "无法更新登录启动路径，请在设置中重新开启登录启动：\(error.localizedDescription)" }
    }

    func setLogin(_ enabled: Bool) {
        do {
            let url = Self.loginURL
            if enabled {
                guard let executable = Bundle.main.executablePath else { return }
                let plist: [String: Any] = ["Label": appID, "ProgramArguments": [executable],
                                            "RunAtLoad": true, "ProcessType": "Interactive"]
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                    .write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            login = enabled
        } catch { self.error = "无法修改登录启动设置：\(error.localizedDescription)" }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let monitor = Monitor()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var alertWindow: NSPanel?
    private var phoneWindow: NSWindow?
    private var nodeWindow: NSWindow?
    private var contactWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: appID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = others.first {
            existing.activate()
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "CodexResetBar"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.clockwise.circle", accessibilityDescription: appName)
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.image?.size = NSSize(width: 16, height: 16)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        popover.behavior = .transient
        monitor.updated = { [weak self] in self?.updateStatus() }
        monitor.presentAlert = { [weak self] title, body, test in self?.showAlert(title: title, body: body, test: test) }
        updateStatus()
        monitor.start()
        if CommandLine.arguments.contains("--enable-login") { monitor.setLogin(true) }
        if CommandLine.arguments.contains("--test-alert") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.monitor.testAlert() }
        }
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.togglePopover() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if [phoneWindow, nodeWindow, contactWindow, alertWindow].compactMap({ $0 }).contains(where: \.isVisible) {
            return true
        }
        if !popover.isShown { togglePopover() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.acknowledge()
    }

    private func updateStatus() {
        let remaining = monitor.snapshot?.windows.map(\.remainingPercent).min()
        let percentage = remaining.map { " \(Int($0))%" } ?? " …"
        statusItem.button?.title = percentage + (monitor.alertPending ? " ●" : monitor.error != nil ? " !" : "")
        statusItem.button?.toolTip = "\(appName) · \(monitor.statusText)\n点击查看额度与提醒设置"
        statusItem.button?.setAccessibilityLabel(appName)
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        let availableHeight = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 720
        let height = min(580, availableHeight - 32)
        popover.contentViewController = NSHostingController(rootView: MonitorView(
            monitor: monitor, phone: monitor.phone, panelHeight: height,
            openCodex: { [weak self] in self?.openCodex() },
            openPhoneSettings: { [weak self] in self?.showPhoneSettings() },
            openNodeSettings: { [weak self] in self?.showNodeSettings() },
            openContact: { [weak self] in self?.showContact() },
            stopAlert: { [weak self] in self?.dismissAlert() }, quit: { NSApp.terminate(nil) }))
        popover.contentSize = NSSize(width: 360, height: height)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func openCodex() {
        dismissAlert()
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private func showAlert(title: String, body: String, test: Bool) {
        popover.performClose(nil)
        alertWindow?.delegate = nil
        alertWindow?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 250),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = test ? "Codex 额度提醒 · 测试" : appName
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 16) {
                Label(title, systemImage: test ? "bell.badge" : "bell.fill")
                    .font(.title2.bold()).foregroundStyle(.teal)
                ScrollView { Text(body).font(.body).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 70)
                Text("声音开启时，每 5 秒重复；确认后停止。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("知道了") { [weak panel] in panel?.close() }.keyboardShortcut(.defaultAction)
                    Spacer()
                    Button("打开 Codex") { [weak self, weak panel] in panel?.close(); self?.openCodex() }
                }
            }.padding(24).frame(width: 420, alignment: .leading))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        alertWindow = panel
    }

    private func dismissAlert() {
        monitor.acknowledge()
        alertWindow?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === alertWindow {
            monitor.acknowledge()
            alertWindow = nil
        }
    }

    private func showPhoneSettings() {
        popover.performClose(nil)
        if let window = phoneWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            let height = min(720, (NSScreen.main?.visibleFrame.height ?? 820) - 64)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: height),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "iPhone 推送设置"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(srgbRed: 0.075, green: 0.12, blue: 0.14, alpha: 1)
            window.contentView = NSHostingView(rootView: PhoneSettingsView(phone: monitor.phone, panelHeight: height,
                openContact: { [weak self] in self?.showContact() }))
            window.center()
            window.makeKeyAndOrderFront(nil)
            phoneWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showNodeSettings() {
        popover.performClose(nil)
        if let window = nodeWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 820)
            let size = NSSize(width: min(900, screen.width - 64), height: min(740, screen.height - 64))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "关键节点提醒"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(srgbRed: 0.075, green: 0.12, blue: 0.14, alpha: 1)
            window.contentView = NSHostingView(rootView: ReminderSettingsView(store: monitor.reminders, phone: monitor.phone,
                testRule: { [weak self] rule in try self?.monitor.testRule(rule) },
                openPhoneSettings: { [weak self] in self?.showPhoneSettings() },
                openContact: { [weak self] in self?.showContact() }, panelSize: size))
            window.center()
            window.makeKeyAndOrderFront(nil)
            nodeWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showContact() {
        popover.performClose(nil)
        if let window = contactWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            let height = min(600, (NSScreen.main?.visibleFrame.height ?? 820) - 64)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: height),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "联系与商业授权"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(srgbRed: 0.075, green: 0.12, blue: 0.14, alpha: 1)
            window.contentView = NSHostingView(rootView: DeveloperContactView(panelHeight: height))
            window.center()
            window.makeKeyAndOrderFront(nil)
            contactWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main struct Entry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--probe") {
            Task {
                do {
                    let data = try await CodexBridge.fetch()
                    let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: data)
                    let summary: [String: Any] = ["plan": snapshot.planName,
                        "ordinaryUsageAllowed": snapshot.ordinaryUsageAllowed as Any? ?? NSNull(),
                        "windows": snapshot.windows.map { ["title": $0.title, "remainingPercent": $0.remainingPercent,
                            "resetsAt": $0.resetsAtDate?.timeIntervalSince1970 as Any? ?? NSNull()] }]
                    let output = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                    print(String(decoding: output, as: UTF8.self))
                    exit(0)
                } catch { fputs("额度读取失败：\(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run()
        } else {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}
