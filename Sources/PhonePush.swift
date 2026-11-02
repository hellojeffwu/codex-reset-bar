import Combine
import Foundation
import Security

enum PhonePushError: LocalizedError {
    case invalidAddress, missingConfiguration, rejected, invalidResponse, network, messageTooLong
    case keychainUnavailable(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请粘贴 Bark 首页的 https://api.day.app/… 地址或设备 Key。"
        case .missingConfiguration: return "请先保存 iPhone 的 Bark 推送地址。"
        case .keychainUnavailable(let status): return "钥匙串拒绝访问（\(status)），手机通知未发送。请在钥匙串访问中重新允许本应用读取 Bark Key，然后重试。"
        case .rejected: return "推送服务未接受请求，请检查 Bark 地址或稍后重试。"
        case .invalidResponse: return "推送服务返回了无法确认的结果，请稍后重试。"
        case .network: return "推送未确认成功，请检查网络后重试。"
        case .messageTooLong: return "推送内容太长：标题最多 100 字，正文最多 500 字；过多表情请适当减少。"
        }
    }
}

struct BarkMessage: Equatable {
    static let defaultTitle = "Codex 额度已恢复"
    static let defaultBody = "电脑检测到 Codex 额度恢复，请打开 Codex 查看。"
    let title: String
    let body: String

    init(title: String = defaultTitle, body: String = defaultBody) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.isEmpty ? Self.defaultTitle : title
        self.body = body.isEmpty ? Self.defaultBody : body
        guard self.title.count <= 100, self.body.count <= 500,
              self.title.utf8.count + self.body.utf8.count <= 2_500 else {
            throw PhonePushError.messageTooLong
        }
    }

    static func load(from defaults: UserDefaults) -> BarkMessage {
        (try? BarkMessage(title: defaults.string(forKey: "phonePushTitle") ?? defaultTitle,
                          body: defaults.string(forKey: "phonePushBody") ?? defaultBody)) ?? (try! BarkMessage())
    }

    func save(to defaults: UserDefaults) {
        defaults.set(title, forKey: "phonePushTitle")
        defaults.set(body, forKey: "phonePushBody")
    }
}

// Pure parsing and request validation are kept separate from the keychain/network.
enum BarkRequest {
    static func deviceKey(from address: String) throws -> String {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let key: String
        if value.contains("://") {
            guard let url = URLComponents(string: value),
                  url.scheme?.lowercased() == "https", url.host?.lowercased() == "api.day.app",
                  url.user == nil, url.password == nil, url.port == nil,
                  let first = url.percentEncodedPath.split(separator: "/").first,
                  let decoded = String(first).removingPercentEncoding else {
                throw PhonePushError.invalidAddress
            }
            key = decoded
        } else { key = value }
        guard !key.isEmpty, key.count <= 256,
              key.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }),
              !["push", "ping", "healthz", "info", "mcp"].contains(key.lowercased()) else {
            throw PhonePushError.invalidAddress
        }
        return key
    }

    static func make(deviceKey: String, test: Bool,
                     title: String = BarkMessage.defaultTitle,
                     body: String = BarkMessage.defaultBody) throws -> URLRequest {
        let key = try self.deviceKey(from: deviceKey)
        let message = try BarkMessage(title: title, body: body)
        var request = URLRequest(url: URL(string: "https://api.day.app/push")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_key": key,
            "title": test ? "【测试】\(message.title)" : message.title,
            "body": test ? "\(message.body)\n\n（测试通知，当前额度未发生变化。）" : message.body,
            "group": "Codex", "level": "timeSensitive", "sound": "alarm", "call": "1"
        ])
        return request
    }

    static func validate(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw PhonePushError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw PhonePushError.rejected }
        struct Reply: Decodable { let code: Int }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw PhonePushError.invalidResponse
        }
        guard reply.code == 200 else { throw PhonePushError.rejected }
    }
}

private enum BarkKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.benxin.codex-reset-bar.bark",
         kSecAttrAccount as String: "device-key"]
    }

    static var exists: Bool {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }

    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Codex 额度提醒：Bark 推送 Key"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw PhonePushError.keychainUnavailable(added) }
        } else if result != errSecSuccess { throw PhonePushError.keychainUnavailable(result) }
    }

    static func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PhonePushError.keychainUnavailable(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw PhonePushError.keychainUnavailable(errSecDecode)
        }
        return key
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor final class PhonePush: ObservableObject {
    static let defaultTitle = BarkMessage.defaultTitle
    static let defaultBody = BarkMessage.defaultBody
    @Published var enabled = UserDefaults.standard.bool(forKey: "phonePushEnabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "phonePushEnabled") }
    }
    @Published private(set) var status: String
    @Published private(set) var isSending = false
    @Published private(set) var messageTitle: String
    @Published private(set) var messageBody: String
    private var pendingMessages: [(test: Bool, message: BarkMessage)] = []
    var hasConfiguration: Bool { BarkKeychain.exists }

    init() {
        let message = BarkMessage.load(from: .standard)
        messageTitle = message.title
        messageBody = message.body
        status = BarkKeychain.exists ? "已配置 iPhone 推送" : "尚未配置 iPhone 推送"
    }

    func saveMessage(title: String, body: String) throws {
        let message = try BarkMessage(title: title, body: body)
        message.save(to: .standard)
        messageTitle = message.title
        messageBody = message.body
        status = "推送内容已保存，后续提醒将使用这份文案"
    }

    func resetMessage() {
        try? saveMessage(title: Self.defaultTitle, body: Self.defaultBody)
    }

    func save(address: String) throws {
        do {
            try BarkKeychain.save(BarkRequest.deviceKey(from: address))
            status = "已保存到钥匙串，可发送测试提醒"
        } catch {
            status = (error as? PhonePushError)?.errorDescription ?? "无法保存推送设置。"
            throw error
        }
    }

    func send(test: Bool, message: BarkMessage? = nil) async {
        guard test || enabled else { return }
        guard let content = message ?? (try? BarkMessage(title: messageTitle, body: messageBody)) else { return }
        pendingMessages.append((test, content))
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }
        while !pendingMessages.isEmpty {
          let next = pendingMessages.removeFirst()
          guard next.test || enabled else { continue }
          status = "正在发送手机提醒…"
          do {
            guard let key = try BarkKeychain.load() else { throw PhonePushError.missingConfiguration }
            let request = try BarkRequest.make(deviceKey: key, test: next.test,
                                               title: next.message.title, body: next.message.body)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 20
            let session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            try BarkRequest.validate(data: data, response: response)
            status = "推送服务已接受，请检查 iPhone"
          } catch {
            status = (error as? PhonePushError)?.errorDescription ?? PhonePushError.network.errorDescription!
          }
        }
    }
}
