import Foundation

@main
struct TaskActivityTests {
    static var checks = 0
    static let future = Date().addingTimeInterval(60)

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }

    static func line(_ type: String, _ payload: [String: Any], date: Date = future) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var data = try! JSONSerialization.data(withJSONObject: ["type": type, "timestamp": formatter.string(from: date), "payload": payload])
        data.append(0x0a)
        return data
    }

    static func metadata(_ id: String = "main-session-abcdef", child: Bool = false) -> Data {
        line("session_meta", ["id": id, "source": child ? ["subagent": ["thread_spawn": [:]]] : "vscode"])
    }

    static func complete(_ id: String, date: Date = future) -> Data {
        line("event_msg", ["type": "task_complete", "turn_id": id, "last_agent_message": "DO_NOT_EXPOSE_CHAT_TEXT"], date: date)
    }

    static func append(_ bytes: Data, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: bytes)
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-task-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("root.jsonl")
        try (metadata() + complete("old")).write(to: file)
        let monitor = TaskActivityMonitor(root: root)
        var signals = await monitor.poll()
        expect(signals.isEmpty, "first poll skips existing history even with future timestamps")
        try append(complete("new"), to: file)
        signals = await monitor.poll()
        expect(signals.count == 1 && signals[0].kind == .completed, "explicit appended completion alerts")
        expect(!signals[0].detail.contains("DO_NOT_EXPOSE"), "notification excludes chat content")
        signals = await monitor.poll()
        expect(signals.isEmpty, "unchanged file does not re-alert")
        try append(complete("new"), to: file)
        signals = await monitor.poll()
        expect(signals.isEmpty, "duplicate turn completion is deduplicated")

        try append(line("event_msg", ["type": "turn_aborted", "turn_id": "cancel", "reason": "interrupted"]), to: file)
        try append(line("response_item", ["type": "message", "role": "assistant", "content": "failed completed waiting"]), to: file)
        signals = await monitor.poll()
        expect(signals.isEmpty, "cancellation and free text never imply completion or failure")

        try append(line("response_item", ["type": "function_call", "name": "functions.request_user_input_async", "call_id": "question", "arguments": "DO_NOT_EXPOSE_QUESTION"]), to: file)
        signals = await monitor.poll()
        expect(signals.count == 1 && signals[0].kind == .needsInput, "explicit question request alerts")
        expect(!signals[0].detail.contains("DO_NOT_EXPOSE"), "question body is not read into notification")

        let items: [[String: Any]] = [
            ["type": "CommandExecution", "id": "search", "status": "failed", "exit_code": 1, "parsed_cmd": [["type": "search"]]],
            ["type": "CommandExecution", "id": "cancelled", "status": "failed", "exit_code": 130],
            ["type": "CommandExecution", "id": "command-error", "status": "failed", "exit_code": 2],
            ["type": "McpToolCall", "id": "tool-error", "status": "failed"],
            ["type": "McpToolCall", "id": "tool-ok", "status": "completed", "result": "failed"]
        ]
        for item in items { try append(line("event_msg", ["type": "item_completed", "item": item]), to: file) }
        signals = await monitor.poll()
        expect(signals.count == 1 && signals[0].kind == .failed, "only first explicit step failure alerts per turn; search misses and cancelled commands do not")
        expect(signals.allSatisfy { $0.detail.contains("不代表整个任务失败") }, "failure notifications describe a step, not a whole task")

        try append(complete("initial-active-turn"), to: file)
        try append(line("event_msg", ["type": "item_completed", "item": ["type": "McpToolCall", "id": "after-complete-error", "status": "failed"]]), to: file)
        signals = await monitor.poll()
        expect(signals.count == 1 && signals[0].kind == .completed, "task completion does not rearm failure notifications")

        let nextTurn = line("event_msg", ["type": "task_started", "turn_id": "next-turn"])
        try append(nextTurn, to: file)
        try append(line("event_msg", ["type": "item_completed", "item": ["type": "McpToolCall", "id": "next-turn-error", "status": "failed"]]), to: file)
        signals = await monitor.poll()
        expect(signals.count == 1 && signals[0].kind == .failed, "explicit next task_started allows its first step failure")

        try append(nextTurn, to: file)
        try append(line("event_msg", ["type": "item_completed", "item": ["type": "McpToolCall", "id": "same-turn-error", "status": "failed"]]), to: file)
        signals = await monitor.poll()
        expect(signals.isEmpty, "duplicate task_started for the same turn cannot rearm alerts")

        let newborn = root.appendingPathComponent("new.jsonl")
        try (metadata("new-session") + complete("already-completed-before-discovery")).write(to: newborn)
        signals = await monitor.poll()
        expect(signals.count == 1 && signals[0].kind == .completed, "new file first batch is read from start")
        let child = root.appendingPathComponent("child.jsonl")
        try (metadata("child-session", child: true) + complete("child-done")).write(to: child)
        signals = await monitor.poll()
        expect(signals.isEmpty, "subagent completions do not spam root-level reminders")
        let imported = root.appendingPathComponent("imported.jsonl")
        try (metadata("imported") + complete("historical", date: Date(timeIntervalSince1970: 1))).write(to: imported)
        signals = await monitor.poll()
        expect(signals.isEmpty, "newly discovered old history does not replay")

        let partial = complete("partial")
        try append(Data(partial.prefix(partial.count / 2)), to: file)
        signals = await monitor.poll()
        expect(signals.isEmpty, "incomplete JSON line waits")
        try append(Data(partial.dropFirst(partial.count / 2)), to: file)
        signals = await monitor.poll()
        expect(signals.count == 1 && signals[0].kind == .completed, "completed partial line is processed once")

        try metadata().write(to: file)
        signals = await monitor.poll()
        expect(signals.isEmpty, "truncation creates a baseline, never a completion")
        try append(complete("after-truncate"), to: file)
        signals = await monitor.poll()
        expect(signals.count == 1, "monitor resumes after truncation baseline")
        try (metadata() + complete("replacement")).write(to: file, options: .atomic)
        signals = await monitor.poll()
        expect(signals.isEmpty, "inode replacement creates a baseline")
        try FileManager.default.removeItem(at: file)
        signals = await monitor.poll()
        expect(signals.isEmpty, "file deletion is not completion or failure")
        let restarted = TaskActivityMonitor(root: root)
        signals = await restarted.poll()
        expect(signals.isEmpty, "restart does not replay existing events")
        print("Task activity tests passed: \(checks) checks")
    }
}
