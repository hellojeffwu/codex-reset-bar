import AppKit
import SwiftUI

enum AppStyle {
    static let accent = Color(red: 0.29, green: 0.86, blue: 0.76)
    static let background = LinearGradient(
        colors: [Color(red: 0.075, green: 0.12, blue: 0.14), Color(red: 0.065, green: 0.075, blue: 0.095)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct SettingsHeader: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon).font(.system(size: 24, weight: .medium))
                .foregroundStyle(AppStyle.accent).frame(width: 48, height: 48)
                .background(AppStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 20, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppStyle.accent)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
}

struct LicenseFooter: View {
    let openContact: () -> Void
    var body: some View {
        HStack {
            Text("仅限个人使用 · 商用需授权").foregroundStyle(.tertiary)
            Spacer()
            Button("联系开发者", action: openContact).buttonStyle(.borderless).foregroundStyle(AppStyle.accent)
        }.font(.system(size: 11))
    }
}

struct DeveloperContactView: View {
    var panelHeight: CGFloat = 600
    @State private var copied = false
    var body: some View {
        ScrollView {
        VStack(spacing: 18) {
            SettingsHeader(title: "联系与商业授权", subtitle: "Codex 额度提醒", icon: "bubble.left.and.bubble.right")
            if let url = Bundle.main.url(forResource: "wechat-qr", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                    .frame(width: 220, height: 220).padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 15))
                    .accessibilityLabel("开发者微信二维码，微信号 wubenxincom")
            }
            Text("微信号  wubenxincom").font(.system(size: 15, weight: .medium)).textSelection(.enabled)
            Button(copied ? "已复制微信号" : "复制微信号") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("wubenxincom", forType: .string)
                copied = true
            }.buttonStyle(.borderedProminent).controlSize(.large)
            Text("个人非商业使用免费。\n用于工作、团队、企业或其他商业用途，\n请先通过微信取得书面授权。")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(26).frame(maxWidth: .infinity)
        }
        .frame(width: 390, height: panelHeight)
        .background(AppStyle.background).tint(AppStyle.accent).preferredColorScheme(.dark)
    }
}
