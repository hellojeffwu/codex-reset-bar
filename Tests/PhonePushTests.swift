import Foundation

@main struct PhonePushTests {
    static func main() throws {
        var count = 0
        func check(_ result: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try result() else { fatalError("FAIL: \(name)") }
            count += 1
        }
        func rejects(_ name: String, _ action: () throws -> Void) {
            do { try action(); fatalError("FAIL: \(name)") } catch { count += 1 }
        }
        let key = "FakeDeviceKey123"
        try check(try BarkRequest.deviceKey(from: " \(key)\n") == key, "bare key")
        try check(try BarkRequest.deviceKey(from: "https://api.day.app/\(key)/") == key, "base address")
        try check(try BarkRequest.deviceKey(from: "https://api.day.app/\(key)/测试标题/测试内容?call=1") == key, "copied test URL")
        try check(try BarkRequest.deviceKey(from: "https://API.DAY.APP/\(key)/body") == key, "case insensitive host")
        for invalid in ["", "https://api.day.app/", "http://api.day.app/\(key)",
                        "https://evil.example/\(key)", "https://api.day.app.evil.example/\(key)",
                        "https://user:password@api.day.app/\(key)", "https://api.day.app:443/\(key)",
                        "https://api.day.app/push", "https://api.day.app/Fake%2FKey", "a b", "https://api.day.app/Fake%0AKey"] {
            rejects("invalid address") { _ = try BarkRequest.deviceKey(from: invalid) }
        }
        let request = try BarkRequest.make(deviceKey: key, test: true)
        try check(request.url?.absoluteString == "https://api.day.app/push", "fixed endpoint without credential")
        try check(request.httpMethod == "POST", "POST")
        try check(request.timeoutInterval == 20, "timeout")
        try check(request.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true, "JSON")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        try check(body["device_key"] == key, "key in JSON only")
        try check(body["call"] == "1" && body["level"] == "timeSensitive" && body["sound"] == "alarm", "30 second time sensitive alert")
        try check(body["title"]?.contains("测试") == true, "test labeled")
        try check(Set(body.keys) == Set(["device_key", "title", "body", "group", "level", "sound", "call"]), "no account or usage details")
        let live = try BarkRequest.make(deviceKey: key, test: false)
        let liveBody = try JSONSerialization.jsonObject(with: live.httpBody!) as! [String: String]
        try check(liveBody["title"] == "Codex 额度已恢复" && liveBody["body"]?.contains(key) == false, "fixed real notification")
        let customTitle = "回来干活 \"Codex\" 🔔"
        let customText = "额度恢复啦！\n第二行：路径 C:\\work，emoji 👨‍👩‍👧‍👦"
        let customRequest = try BarkRequest.make(deviceKey: key, test: false, title: customTitle, body: customText)
        let customBody = try JSONSerialization.jsonObject(with: customRequest.httpBody!) as! [String: String]
        try check(customBody["title"] == customTitle && customBody["body"] == customText, "custom Chinese quotes newlines and emoji survive JSON")
        try check(customRequest.url == request.url && customBody["device_key"] == key, "message cannot change destination or device key")
        let customTest = try BarkRequest.make(deviceKey: key, test: true, title: customTitle, body: customText)
        let customTestBody = try JSONSerialization.jsonObject(with: customTest.httpBody!) as! [String: String]
        try check(customTestBody["title"] == "【测试】\(customTitle)", "test keeps custom title with explicit marker")
        try check(customTestBody["body"]?.hasPrefix(customText) == true && customTestBody["body"]?.contains("当前额度未发生变化") == true, "test previews saved body without claiming recovery")
        let blank = try BarkMessage(title: " \n ", body: "\t")
        try check(blank.title == BarkMessage.defaultTitle && blank.body == BarkMessage.defaultBody, "blank content falls back to defaults")
        let trimmed = try BarkMessage(title: " 标题 ", body: "\n正文\n下一行\n")
        try check(trimmed.title == "标题" && trimmed.body == "正文\n下一行", "trim outside whitespace but preserve internal lines")
        rejects("title length limit") { _ = try BarkMessage(title: String(repeating: "字", count: 101)) }
        rejects("body length limit") { _ = try BarkMessage(body: String(repeating: "字", count: 501)) }
        rejects("combined emoji byte limit") { _ = try BarkMessage(body: String(repeating: "👨‍👩‍👧‍👦", count: 110)) }
        let maxMessage = try BarkRequest.make(deviceKey: key, test: true, title: String(repeating: "题", count: 100), body: String(repeating: "文", count: 500))
        try check(maxMessage.httpBody!.count < 3_500, "allowed Chinese message retains room for APNs metadata")
        let suite = "codex-phone-tests.\(UUID().uuidString)"
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        try check(BarkMessage.load(from: isolated) == BarkMessage(), "missing preferences load defaults")
        let saved = try BarkMessage(title: customTitle, body: customText)
        saved.save(to: isolated)
        let reloaded = UserDefaults(suiteName: suite)!
        try check(BarkMessage.load(from: reloaded) == saved, "saved content survives a new preferences reader")
        try BarkMessage().save(to: isolated)
        try check(BarkMessage.load(from: reloaded) == BarkMessage(), "reset defaults replaces saved content")
        isolated.set(String(repeating: "x", count: 501), forKey: "phonePushBody")
        try check(BarkMessage.load(from: reloaded) == BarkMessage(), "invalid stored content safely loads defaults")
        let success = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        try BarkRequest.validate(data: Data("{\"code\":200,\"message\":\"success\"}".utf8), response: success)
        count += 1
        rejects("service rejects despite HTTP success") {
            try BarkRequest.validate(data: Data("{\"code\":400}".utf8), response: success)
        }
        rejects("malformed JSON") { try BarkRequest.validate(data: Data("bad".utf8), response: success) }
        rejects("missing code") { try BarkRequest.validate(data: Data("{}".utf8), response: success) }
        for code in [301, 400, 500] {
            rejects("HTTP failure or redirect") {
                let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
                try BarkRequest.validate(data: Data("{\"code\":200}".utf8), response: response)
            }
        }
        print("PASS: \(count) phone push request and response checks (no network requests or keychain writes)")
    }
}
