import SwiftUI

@MainActor struct PhoneSettingsView: View {
    @ObservedObject var phone: PhonePush
    let panelHeight: CGFloat
    let openContact: () -> Void
    @State private var address = ""
    @State private var saveError: String?
    @State private var messageTitle: String
    @State private var messageBody: String
    @State private var messageStatus: String?

    init(phone: PhonePush, panelHeight: CGFloat = 720, openContact: @escaping () -> Void = {}) {
        self.phone = phone
        self.panelHeight = panelHeight
        self.openContact = openContact
        _messageTitle = State(initialValue: phone.messageTitle)
        _messageBody = State(initialValue: phone.messageBody)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(title: "iPhone 推送", subtitle: "把重要提醒送到手机，不错过额度恢复。",
                           icon: "iphone.radiowaves.left.and.right").padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionCard
                    messageCard
                    Label("手机端请求长响约 30 秒。请在 iPhone 允许 Bark 通知；静音和专注设置会影响响铃。",
                          systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("推送地址保存在本机钥匙串。通知只包含你设置的文案；电脑需要保持运行并联网。")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 24).padding(.bottom, 20)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().padding(.horizontal, 24)
            LicenseFooter(openContact: openContact).padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 540, height: panelHeight).background(AppStyle.background)
        .tint(AppStyle.accent).preferredColorScheme(.dark)
    }

    private var connectionCard: some View {
        SettingsCard(title: "连接 Bark", icon: "link") {
            HStack {
                Label(phone.hasConfiguration ? "推送地址已保存" : "等待配置推送地址",
                      systemImage: phone.hasConfiguration ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 12)).foregroundStyle(phone.hasConfiguration ? AppStyle.accent : .secondary)
                Spacer()
                Toggle("启用 iPhone 推送", isOn: $phone.enabled)
                    .toggleStyle(.switch).controlSize(.small).disabled(!phone.hasConfiguration)
            }
            if !phone.hasConfiguration {
                Text("在 iPhone 安装 Bark 并允许通知，把首页的推送地址粘贴到这里。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Link("在 App Store 查看 Bark", destination: URL(string: "https://apps.apple.com/app/id1403753865")!)
                    .font(.system(size: 12))
            }
            SecureField(phone.hasConfiguration ? "粘贴新地址可替换当前配置" : "https://api.day.app/你的推送密钥", text: $address)
                .textFieldStyle(.roundedBorder).controlSize(.large).accessibilityLabel("Bark 推送地址")
            HStack {
                Text("支持官方推送地址或设备 Key").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button("保存并启用", action: saveAddress).buttonStyle(.borderedProminent)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Divider()
            HStack(alignment: .top, spacing: 8) {
                if phone.isSending { ProgressView().controlSize(.small) }
                else { Image(systemName: "iphone").foregroundStyle(AppStyle.accent) }
                Text(saveError ?? phone.status).font(.system(size: 12))
                    .foregroundStyle(saveError == nil ? Color.secondary : .orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }

    private var messageCard: some View {
        SettingsCard(title: "额度恢复文案", icon: "text.bubble") {
            Text("恢复提醒的标题").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Codex 额度已恢复", text: $messageTitle).textFieldStyle(.roundedBorder)
                .controlSize(.large).accessibilityLabel("推送标题")
            Text("恢复提醒的正文").font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $messageBody).font(.system(size: 13))
                .scrollContentBackground(.hidden).padding(8).frame(height: 110)
                .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.09)))
                .accessibilityLabel("推送正文")
            Text("标题最多 100 字，正文最多 500 字。编辑后保存；关键节点使用各自的规则文案。")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            HStack {
                Button("保存文案", action: saveMessage).buttonStyle(.borderedProminent)
                Button("恢复默认") {
                    phone.resetMessage()
                    messageTitle = phone.messageTitle
                    messageBody = phone.messageBody
                    messageStatus = "已恢复默认文案。"
                }.buttonStyle(.borderless)
                Spacer()
                Button {
                    Task { await phone.send(test: true) }
                } label: {
                    Label(phone.isSending ? "发送中…" : "测试已保存文案", systemImage: "paperplane")
                }.buttonStyle(.bordered).disabled(!phone.hasConfiguration || phone.isSending)
            }
            if let messageStatus {
                Text(messageStatus).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func saveAddress() {
        do {
            try phone.save(address: address)
            address = ""
            saveError = nil
            phone.enabled = true
        } catch { saveError = error.localizedDescription }
    }

    private func saveMessage() {
        do {
            try phone.saveMessage(title: messageTitle, body: messageBody)
            messageTitle = phone.messageTitle
            messageBody = phone.messageBody
            messageStatus = "已保存，后续额度恢复提醒和本页测试会使用这段文案。"
        } catch { messageStatus = error.localizedDescription }
    }
}
