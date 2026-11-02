using System.Text.Json;

namespace CodexResetBar.Core;

public enum TaskSignalKind { Completed, Failed, NeedsInput }
public sealed record TaskSignal(string Id, TaskSignalKind Kind, string Detail, DateTimeOffset Date);

/// <summary>Incrementally reads explicit rollout events. It never interprets chat text or tool output.</summary>
public sealed class TaskActivityMonitor
{
    private sealed class Cursor
    {
        public long CreationTicks;
        public long Offset;
        public byte[] Pending = [];
        public bool DiscardPartial;
        public string? SessionId;
        public bool IsMainSession;
        public string? ActiveTurnId;
        public bool FailureReported;
    }

    private readonly string root;
    private readonly DateTimeOffset startedAt;
    private readonly Dictionary<string, Cursor> cursors = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> seen = new(StringComparer.Ordinal);
    private readonly SemaphoreSlim gate = new(1, 1);
    private bool baselined;
    private const int MaximumRead = 4 * 1024 * 1024;
    private const int MaximumLine = 2 * 1024 * 1024;

    public TaskActivityMonitor(string? root = null, DateTimeOffset? startedAt = null)
    {
        this.root = root ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "sessions");
        this.startedAt = startedAt ?? DateTimeOffset.UtcNow;
    }

    public async Task<IReadOnlyList<TaskSignal>> PollAsync(CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            var signals = new List<TaskSignal>();
            if (!Directory.Exists(root)) { baselined = true; return signals; }
            string[] files;
            try
            {
                files = Directory.EnumerateFiles(root, "*.jsonl", new EnumerationOptions
                {
                    RecurseSubdirectories = true, IgnoreInaccessible = true,
                    AttributesToSkip = FileAttributes.Hidden | FileAttributes.System | FileAttributes.ReparsePoint
                }).ToArray();
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return signals; }
            foreach (var file in files)
            {
                cancellationToken.ThrowIfCancellationRequested();
                try
                {
                    var info = new FileInfo(file);
                    var size = info.Length;
                    var creation = info.CreationTimeUtc.Ticks;
                    cursors.TryGetValue(file, out var previous);
                    var replaced = previous != null && (previous.CreationTicks != creation || size < previous.Offset);
                    var cursor = previous ?? new Cursor { CreationTicks = creation };
                    await using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete,
                        4096, FileOptions.Asynchronous | FileOptions.SequentialScan);
                    if (!baselined || replaced)
                    {
                        cursor = new() { CreationTicks = creation, Offset = size };
                        await ReadMetadataPrefixAsync(stream, cursor, cancellationToken);
                        if (size > 0)
                        {
                            stream.Position = size - 1;
                            var tail = new byte[1];
                            cursor.DiscardPartial = await stream.ReadAsync(tail, cancellationToken) != 1 || tail[0] != (byte)'\n';
                        }
                        cursors[file] = cursor;
                        continue;
                    }
                    if (size <= cursor.Offset) continue;
                    stream.Position = cursor.Offset;
                    var bytes = new byte[(int)Math.Min(size - cursor.Offset, MaximumRead)];
                    var count = await ReadAvailableAsync(stream, bytes, cancellationToken);
                    if (count == 0) continue;
                    var from = 0;
                    if (cursor.DiscardPartial)
                    {
                        var end = Array.IndexOf(bytes, (byte)'\n', 0, count);
                        if (end < 0) { cursor.Offset += count; cursors[file] = cursor; continue; }
                        from = end + 1;
                        cursor.DiscardPartial = false;
                    }
                    var pending = new byte[cursor.Pending.Length + count - from];
                    cursor.Pending.CopyTo(pending, 0);
                    Array.Copy(bytes, from, pending, cursor.Pending.Length, count - from);
                    var lineStart = 0;
                    for (var index = 0; index < pending.Length; index++)
                    {
                        if (pending[index] != (byte)'\n') continue;
                        var length = index - lineStart;
                        if (length <= MaximumLine)
                        {
                            var line = pending.AsMemory(lineStart, length);
                            ReadMetadata(line, cursor);
                            var signal = SignalFrom(line, cursor);
                            if (signal != null && seen.Add(signal.Id)) signals.Add(signal);
                        }
                        lineStart = index + 1;
                    }
                    cursor.Pending = pending[lineStart..];
                    if (cursor.Pending.Length > MaximumLine) { cursor.Pending = []; cursor.DiscardPartial = true; }
                    cursor.Offset += count;
                    cursors[file] = cursor;
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    // Unreadable/rotating log files are not task failures. Retry the prior offset next time.
                }
            }
            baselined = true;
            var existing = files.ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (var stale in cursors.Keys.Where(file => !existing.Contains(file)).ToArray()) cursors.Remove(stale);
            return signals.OrderBy(signal => signal.Date).ToList();
        }
        finally { gate.Release(); }
    }

    private static async Task<int> ReadAvailableAsync(Stream stream, byte[] bytes, CancellationToken token)
    {
        var total = 0;
        while (total < bytes.Length)
        {
            var count = await stream.ReadAsync(bytes.AsMemory(total), token);
            if (count == 0) break;
            total += count;
        }
        return total;
    }

    private static async Task ReadMetadataPrefixAsync(Stream stream, Cursor cursor, CancellationToken token)
    {
        // The baseline is EOF; only the first metadata line needs reading, not megabytes of history per file.
        using var prefix = new MemoryStream();
        var chunk = new byte[4096];
        while (prefix.Length < MaximumLine)
        {
            var count = await stream.ReadAsync(chunk.AsMemory(0, (int)Math.Min(chunk.Length, MaximumLine - prefix.Length)), token);
            if (count == 0) return;
            var newline = Array.IndexOf(chunk, (byte)'\n', 0, count);
            prefix.Write(chunk, 0, newline >= 0 ? newline : count);
            if (newline < 0) continue;
            ReadMetadata(prefix.ToArray(), cursor);
            return;
        }
    }

    private static void ReadMetadata(ReadOnlyMemory<byte> line, Cursor cursor)
    {
        if (cursor.SessionId != null) return;
        try
        {
            using var document = JsonDocument.Parse(line);
            var row = document.RootElement;
            if (Text(row, "type") != "session_meta" || !Object(row, "payload", out var payload)) return;
            var session = Text(payload, "id");
            if (string.IsNullOrEmpty(session)) return;
            cursor.SessionId = session;
            var isSubagent = payload.TryGetProperty("source", out var source) &&
                (source.ValueKind == JsonValueKind.Object && source.TryGetProperty("subagent", out _) ||
                 source.ValueKind == JsonValueKind.String && source.GetString()?.Contains("subagent", StringComparison.OrdinalIgnoreCase) == true);
            cursor.IsMainSession = !isSubagent && string.IsNullOrEmpty(Text(payload, "parent_thread_id"));
        }
        catch (JsonException) { }
    }

    private TaskSignal? SignalFrom(ReadOnlyMemory<byte> line, Cursor cursor)
    {
        if (!cursor.IsMainSession || cursor.SessionId == null) return null;
        try
        {
            using var document = JsonDocument.Parse(line);
            var row = document.RootElement;
            if (!Object(row, "payload", out var payload) ||
                !DateTimeOffset.TryParse(Text(row, "timestamp"), System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.RoundtripKind, out var date) || date < startedAt) return null;
            var rowType = Text(row, "type");
            var type = Text(payload, "type");
            var session = cursor.SessionId;
            var label = $"本地 Codex 对话 · {session[Math.Max(0, session.Length - 6)..]}";
            if (rowType == "event_msg" && type == "task_started" && Text(payload, "turn_id") is { } newTurn)
            {
                if (newTurn != cursor.ActiveTurnId) { cursor.ActiveTurnId = newTurn; cursor.FailureReported = false; }
                return null;
            }
            if (rowType == "event_msg" && type == "task_complete" && Text(payload, "turn_id") is { } turn)
                return new($"{session}:{turn}:completed", TaskSignalKind.Completed, $"{label} 的这一轮已完成。", date);
            if (rowType == "response_item" && type == "function_call" && Text(payload, "name") is { } name &&
                name.Split('.').Last() is "request_user_input" or "request_user_input_async" && Text(payload, "call_id") is { } call)
                return new($"{session}:{call}:input", TaskSignalKind.NeedsInput, $"{label} 发出了一个需要你查看的问题。", date);
            if (rowType != "event_msg" || type != "item_completed" || !Object(payload, "item", out var item) ||
                Text(item, "type") is not ("CommandExecution" or "McpToolCall" or "FileChange") ||
                !string.Equals(Text(item, "status"), "failed", StringComparison.OrdinalIgnoreCase) || Text(item, "id") is not { } itemId) return null;
            if (Text(item, "type") == "CommandExecution" && item.TryGetProperty("exit_code", out var exit) &&
                exit.ValueKind == JsonValueKind.Number && exit.TryGetInt32(out var exitCode))
            {
                if (exitCode is -1 or 130 or 137 or 143) return null;
                if (exitCode == 1 && item.TryGetProperty("parsed_cmd", out var parsed) && parsed.ValueKind == JsonValueKind.Array &&
                    parsed.GetArrayLength() > 0 && parsed.EnumerateArray().All(command => Text(command, "type") == "search")) return null;
            }
            var id = $"{session}:{itemId}:step-failed";
            if (cursor.FailureReported || seen.Contains(id)) return null;
            cursor.FailureReported = true;
            return new(id, TaskSignalKind.Failed, $"{label} 有一个执行步骤报错；不代表整个任务失败，Codex 可能继续重试。", date);
        }
        catch (JsonException) { return null; }
    }

    private static bool Object(JsonElement parent, string key, out JsonElement value)
    {
        value = default;
        return parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(key, out value) && value.ValueKind == JsonValueKind.Object;
    }
    private static string? Text(JsonElement parent, string key) => parent.ValueKind == JsonValueKind.Object &&
        parent.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}
