import AppKit
import SwiftUI

@MainActor struct MonitorView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var phone: PhonePush
    let panelHeight: CGFloat
    var openCodex: () -> Void
    var openPhoneSettings: () -> Void
    var openNodeSettings: () -> Void
    var openContact: () -> Void
    var stopAlert: () -> Void
    var quit: () -> Void
    @State private var settings = false

    private let accent = AppStyle.accent

    var body: some View {
        VStack(spacing: 0) {
            header.padding(20)
            HStack(spacing: 4) {
                tab("额度概览", selected: !settings) { settings = false }
                tab("提醒设置", selected: settings) { settings = true }
            }
            .padding(4).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
            .padding(.horizontal, 20).padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if settings { notificationSettings } else { overview }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .frame(width: 360, height: panelHeight)
        .background(AppStyle.background)
        .tint(accent).preferredColorScheme(.dark)
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color(red: 0.04, green: 0.13, blue: 0.13) : Color.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(selected ? accent : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(selected ? "已选中" : "未选中")
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 23, weight: .medium)).foregroundStyle(accent)
                .frame(width: 42, height: 42)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 5) {
                Text("Codex 额度提醒").font(.system(size: 16, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(monitor.error == nil ? accent : .orange).frame(width: 5, height: 5)
                    Text(monitor.statusText)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .accessibilityLabel(monitor.statusText)
            }
            Spacer(minLength: 0)
            if let plan = monitor.snapshot?.planName {
                Text(plan.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(accent).padding(.horizontal, 9).padding(.vertical, 5)
                    .background(accent.opacity(0.10), in: Capsule())
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            if monitor.alertPending {
                HStack(spacing: 9) {
                    Image(systemName: "bell.badge.fill")
                    Text("有提醒等待确认").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("停止提醒", action: stopAlert).controlSize(.small)
                }
                .foregroundStyle(.orange).padding(12)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            }
            if let snapshot = monitor.snapshot, !snapshot.windows.isEmpty {
                ForEach(snapshot.windows) { window in quotaCard(window) }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right").font(.title).foregroundStyle(accent)
                    Text(monitor.refreshing ? "正在读取额度" : "等待额度数据").font(.headline)
                    Text("连接这台 Mac 上已登录的 Codex")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 34)
            }
            if let error = monitor.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if monitor.snapshot != nil {
                    Text("当前显示最近成功读取的数据。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let event = monitor.history.first {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Label("最近提醒", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        Text(event.date.formatted(.dateTime.month().day().hour().minute()))
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(event.title).font(.system(size: 12, weight: .medium))
                    Text(event.body).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(3).textSelection(.enabled)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            }
            Text("按实际额度恢复提醒，预计时间仅供参考。")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func quotaCard(_ window: DisplayWindow) -> some View {
        let color: Color = window.remainingPercent <= 10 ? .orange : accent
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(window.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chart.bar.fill").foregroundStyle(color.opacity(0.6))
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(window.remainingPercent))")
                    .font(.system(size: 54, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("%").font(.system(size: 24, weight: .medium, design: .rounded)).foregroundStyle(color)
                Spacer()
                Text("剩余额度").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ProgressView(value: window.remainingPercent, total: 100).tint(color)
                .accessibilityLabel("剩余额度").accessibilityValue("\(Int(window.remainingPercent))%")
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            HStack(alignment: .top) {
                Label("预计重置", systemImage: "arrow.clockwise")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if let date = window.resetsAtDate {
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(countdown(date, now: context.date))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("暂未提供").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [color.opacity(0.11), Color.white.opacity(0.025)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(color.opacity(0.16), lineWidth: 1))
    }

    private var notificationSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("提醒方式").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                switchRow("重复声音", detail: "每 5 秒响一次，确认后停止", icon: "speaker.wave.2", value: $monitor.sound)
                Divider().padding(.leading, 45)
                switchRow("弹窗提醒", detail: "在电脑上显示提醒窗口", icon: "macwindow", value: $monitor.popup)
                Divider().padding(.leading, 45)
                switchRow("登录时启动", detail: "登录 Mac 后自动开始监测", icon: "power",
                          value: Binding(get: { monitor.login }, set: { monitor.setLogin($0) }))
            }
            .padding(.horizontal, 12)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            Text("更多设置").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                settingsLink("iPhone 推送", detail: phone.enabled ? "Bark 推送已开启" : "配置 Bark 手机通知",
                             icon: "iphone.radiowaves.left.and.right", action: openPhoneSettings)
                Divider().padding(.leading, 45)
                settingsLink("关键节点提醒", detail: "自定义额度、时间和任务节点",
                             icon: "slider.horizontal.3", action: openNodeSettings)
                Divider().padding(.leading, 45)
                settingsLink("联系与商业授权", detail: "微信 wubenxincom · 个人使用免费",
                             icon: "bubble.left.and.bubble.right", action: openContact)
            }
            .padding(.horizontal, 12)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            HStack {
                Button { monitor.testAlert() } label: {
                    Label("测试声音与弹窗", systemImage: "bell.badge")
                }
                .buttonStyle(.bordered).controlSize(.small)
                Spacer()
                Button("退出监测", action: quit).buttonStyle(.borderless)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("测试会立即响铃；手机通知在 iPhone 设置中单独测试。")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func switchRow(_ title: String, detail: String, icon: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }.padding(.vertical, 13)
    }

    private func settingsLink(_ title: String, detail: String, icon: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(.vertical, 14).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Divider().overlay(Color.white.opacity(0.04))
            HStack {
                HStack(spacing: 5) {
                    if monitor.refreshing { ProgressView().controlSize(.mini).scaleEffect(0.7) }
                    Text(monitor.refreshing ? "正在检查…" : monitor.lastSuccess.map {
                        "更新于 " + $0.formatted(date: .omitted, time: .standard)
                    } ?? "尚未成功检查")
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button { monitor.refresh() } label: {
                    Label("刷新", systemImage: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.borderless).disabled(monitor.refreshing).help("立即检查额度")
            }
            Button(action: openCodex) {
                HStack {
                    Text("打开 Codex").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.up.forward").font(.system(size: 11, weight: .semibold))
                }.padding(.vertical, 4).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(.horizontal, 20).padding(.bottom, 18)
    }

    private func countdown(_ date: Date, now: Date) -> String {
        let minutes = Int(ceil(date.timeIntervalSince(now) / 60))
        if minutes <= 0 { return "预计时间已到，继续监测实际恢复" }
        if minutes >= 1440 { return "约 \(minutes / 1440) 天 \((minutes % 1440) / 60) 小时后" }
        if minutes >= 60 { return "约 \(minutes / 60) 小时 \(minutes % 60) 分钟后" }
        return "约 \(minutes) 分钟后"
    }
}
