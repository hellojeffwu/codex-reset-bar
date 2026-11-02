import AppKit
import Foundation
import Darwin

enum CodexBridge {
    enum BridgeError: LocalizedError {
        case appMissing, launchFailed, timedOut, disconnected, loginRequired, requestFailed, invalidResponse

        var errorDescription: String? {
            switch self {
            case .appMissing: return "找不到本机 Codex，请先安装或打开 Codex。"
            case .launchFailed: return "无法启动 Codex 的额度查询服务，请确认 Codex 安装完整。"
            case .timedOut: return "额度查询超时，将在下次自动刷新时重试。"
            case .disconnected: return "Codex 额度查询服务已断开，将自动重试。"
            case .loginRequired: return "请打开 Codex，确认已登录 ChatGPT 账号。"
            case .requestFailed: return "暂时无法取得额度，请检查网络和 Codex 登录状态。"
            case .invalidResponse: return "Codex 返回了无法识别的额度数据，请更新 Codex 后重试。"
            }
        }
    }

    /// Read the signed-in account's quota through Codex's own protocol.
    /// This never starts a thread or turn and never reads authentication files.
    static func fetch() async throws -> Data {
        let executable = try await MainActor.run { try executableURL() }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try fetchSynchronously(executable: executable)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    @MainActor
    private static func executableURL() throws -> URL {
        var applications: [URL] = []
        if let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            applications.append(installed)
        }
        applications += [URL(fileURLWithPath: "/Applications/Codex.app"),
                         URL(fileURLWithPath: "/Applications/ChatGPT.app")]
        for application in applications {
            for relative in ["Contents/Resources/codex-cli/bin/codex", "Contents/Resources/codex"] {
                let executable = application.appendingPathComponent(relative)
                if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
            }
        }
        throw BridgeError.appMissing
    }

    private static func fetchSynchronously(executable: URL) throws -> Data {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        // A server that exits during the handshake must not terminate the menu app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // Server diagnostics can include account details. Never persist or display them.
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw BridgeError.launchFailed }

        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let stopDeadline = ProcessInfo.processInfo.systemUptime + 1
                while process.isRunning && ProcessInfo.processInfo.systemUptime < stopDeadline {
                    Thread.sleep(forTimeInterval: 0.025)
                }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }

        let deadline = ProcessInfo.processInfo.systemUptime + 20
        var buffer = Data()
        try send(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "codex_reset_bar", "title": "Codex 额度提醒", "version": "1.0"],
            "capabilities": ["experimentalApi": false, "requestAttestation": false]
        ]], to: input.fileHandleForWriting)
        _ = try response(id: 1, from: output.fileHandleForReading, buffer: &buffer, deadline: deadline)
        try send(["method": "initialized", "params": [:]], to: input.fileHandleForWriting)
        try send(["id": 2, "method": "account/rateLimits/read", "params": [
            "excludeResetCreditDetails": true
        ]], to: input.fileHandleForWriting)
        let result = try response(id: 2, from: output.fileHandleForReading, buffer: &buffer, deadline: deadline)
        guard JSONSerialization.isValidJSONObject(result) else { throw BridgeError.invalidResponse }
        return try JSONSerialization.data(withJSONObject: result)
    }

    private static func send(_ request: [String: Any], to handle: FileHandle) throws {
        var bytes = try JSONSerialization.data(withJSONObject: request)
        bytes.append(0x0a)
        do { try handle.write(contentsOf: bytes) }
        catch { throw BridgeError.disconnected }
    }

    private static func response(id: Int, from handle: FileHandle, buffer: inout Data,
                                 deadline: TimeInterval) throws -> [String: Any] {
        while ProcessInfo.processInfo.systemUptime < deadline {
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (object["id"] as? NSNumber)?.intValue == id else { continue }
                if let error = object["error"] as? [String: Any] {
                    let message = (error["message"] as? String ?? "").lowercased()
                    if message.contains("auth") || message.contains("log in") || message.contains("login") || message.contains("401") {
                        throw BridgeError.loginRequired
                    }
                    throw BridgeError.requestFailed
                }
                guard let result = object["result"] as? [String: Any] else { throw BridgeError.invalidResponse }
                return result
            }

            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            let ready = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1_000, 250)))
            if ready < 0 {
                if errno == EINTR { continue }
                throw BridgeError.disconnected
            }
            if ready == 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(handle.fileDescriptor, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw BridgeError.disconnected }
            buffer.append(contentsOf: chunk.prefix(count))
            guard buffer.count <= 8 * 1_024 * 1_024 else { throw BridgeError.invalidResponse }
        }
        throw BridgeError.timedOut
    }
}
