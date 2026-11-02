import Foundation

enum TaskSignalKind: String, Sendable {
    case completed, failed, needsInput
}

struct TaskSignal: Sendable {
    let id: String
    let kind: TaskSignalKind
    let detail: String
    let date: Date
}

/// Watches explicit local rollout events. Silence, cancellation and process exit
/// never imply success or failure. Chat text, tool arguments and outputs are ignored.
actor TaskActivityMonitor {
    private struct Cursor {
        var inode: UInt64
        var offset: UInt64
        var pending = Data()
        var discardPartial = false
        var sessionID: String?
        var isMainSession = false
        var activeTurnID: String?
        var failureReported = false
    }

    private let root: URL
    private let startedAt = Date()
    private var baselined = false
    private var cursors: [String: Cursor] = [:]
    private var seen: Set<String> = []
    private let maximumRead = 4 * 1_024 * 1_024
    private let maximumLine = 2 * 1_024 * 1_024

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")) {
        self.root = root
    }

    func poll() async -> [TaskSignal] {
        pollSynchronously()
    }

    private func pollSynchronously() -> [TaskSignal] {
        defer { baselined = true }
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        var signals: [TaskSignal] = []
        for case let url as URL in files where url.pathExtension == "jsonl" {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { continue }
            var cursor = cursors[url.path] ?? Cursor(inode: inode, offset: 0)
            let replaced = cursors[url.path] != nil && (cursor.inode != inode || size < cursor.offset)
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }

            if !baselined || replaced {
                cursor = Cursor(inode: inode, offset: size)
                if let prefix = try? handle.read(upToCount: maximumLine),
                   let end = prefix.firstIndex(of: 0x0a) {
                    readMetadata(Data(prefix[..<end]), into: &cursor)
                }
                if size > 0 {
                    try? handle.seek(toOffset: size - 1)
                    cursor.discardPartial = (try? handle.read(upToCount: 1)) != Data([0x0a])
                }
                cursors[url.path] = cursor
                continue
            }

            guard size > cursor.offset else { continue }
            do {
                try handle.seek(toOffset: cursor.offset)
                guard let bytes = try handle.read(upToCount: min(maximumRead, Int(size - cursor.offset))), !bytes.isEmpty else { continue }
                cursor.offset += UInt64(bytes.count)
                var fresh = bytes
                if cursor.discardPartial {
                    if let end = fresh.firstIndex(of: 0x0a) {
                        fresh.removeSubrange(...end)
                        cursor.discardPartial = false
                    } else {
                        cursors[url.path] = cursor
                        continue
                    }
                }
                cursor.pending.append(fresh)
                while let end = cursor.pending.firstIndex(of: 0x0a) {
                    let line = Data(cursor.pending[..<end])
                    cursor.pending.removeSubrange(...end)
                    guard line.count <= maximumLine else { continue }
                    readMetadata(line, into: &cursor)
                    if let signal = signal(from: line, cursor: &cursor), seen.insert(signal.id).inserted {
                        signals.append(signal)
                    }
                }
                if cursor.pending.count > maximumLine {
                    cursor.pending.removeAll(keepingCapacity: false)
                    cursor.discardPartial = true
                }
                cursors[url.path] = cursor
            } catch {
                // Keep the last successful offset and retry; failed reads are not task failures.
                continue
            }
        }
        return signals.sorted { $0.date < $1.date }
    }

    private func readMetadata(_ line: Data, into cursor: inout Cursor) {
        guard cursor.sessionID == nil,
              let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              row["type"] as? String == "session_meta",
              let payload = row["payload"] as? [String: Any],
              let sessionID = payload["id"] as? String else { return }
        cursor.sessionID = sessionID
        let source = payload["source"] as? [String: Any]
        let parent = payload["parent_thread_id"] as? String ?? ""
        cursor.isMainSession = source?["subagent"] == nil && parent.isEmpty
    }

    private func signal(from line: Data, cursor: inout Cursor) -> TaskSignal? {
        guard cursor.isMainSession, let sessionID = cursor.sessionID,
              let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = row["payload"] as? [String: Any],
              let date = eventDate(row["timestamp"]), date >= startedAt else { return nil }
        let rowType = row["type"] as? String
        let type = payload["type"] as? String
        let label = "本地 Codex 对话 · \(sessionID.suffix(6))"

        if rowType == "event_msg", type == "task_started", let turnID = payload["turn_id"] as? String {
            if turnID != cursor.activeTurnID {
                cursor.activeTurnID = turnID
                cursor.failureReported = false
            }
            return nil
        }
        if rowType == "event_msg", type == "task_complete", let turnID = payload["turn_id"] as? String {
            return TaskSignal(id: "\(sessionID):\(turnID):completed", kind: .completed,
                              detail: "\(label) 的这一轮已完成。", date: date)
        }
        if rowType == "response_item", type == "function_call",
           let name = payload["name"] as? String,
           ["request_user_input", "request_user_input_async"].contains(name.split(separator: ".").last.map(String.init) ?? name),
           let callID = payload["call_id"] as? String {
            return TaskSignal(id: "\(sessionID):\(callID):input", kind: .needsInput,
                              detail: "\(label) 发出了一个需要你查看的问题。", date: date)
        }
        guard rowType == "event_msg", type == "item_completed",
              let item = payload["item"] as? [String: Any],
              let itemType = item["type"] as? String,
              ["CommandExecution", "McpToolCall", "FileChange"].contains(itemType),
              (item["status"] as? String)?.lowercased() == "failed",
              let itemID = item["id"] as? String else { return nil }
        if itemType == "CommandExecution", let exitCode = item["exit_code"] as? Int {
            // Interrupts / killed processes are not a failed task. Search exit 1 means no matches.
            if [-1, 130, 137, 143].contains(exitCode) { return nil }
            let parsed = item["parsed_cmd"] as? [[String: Any]] ?? []
            if exitCode == 1 && !parsed.isEmpty && parsed.allSatisfy({ $0["type"] as? String == "search" }) { return nil }
        }
        let signalID = "\(sessionID):\(itemID):step-failed"
        // Repeated tool failures in one turn must not create an alert/timeout feedback loop.
        // Only an explicit new task_started event arms the next failure notification.
        guard !cursor.failureReported, !seen.contains(signalID) else { return nil }
        cursor.failureReported = true
        return TaskSignal(id: signalID, kind: .failed,
                          detail: "\(label) 有一个执行步骤报错；不代表整个任务失败，Codex 可能继续重试。", date: date)
    }

    private func eventDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
