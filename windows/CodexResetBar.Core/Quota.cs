using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CodexResetBar.Core;

public static class CoreJson
{
    public static JsonSerializerOptions Options { get; } = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter() }
    };
}

public sealed record QuotaDisplayWindow(string Id, string Title, double UsedPercent,
    int? DurationMinutes, DateTimeOffset? ResetsAt)
{
    public double RemainingPercent => Math.Clamp(100 - UsedPercent, 0, 100);
}

public sealed record UsageSnapshot(string? AccountId, bool? OrdinaryUsageAllowed,
    string PlanName, IReadOnlyList<QuotaDisplayWindow> Windows);

public static class QuotaParser
{
    public static UsageSnapshot Parse(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new JsonException();
            var buckets = new List<(string Id, JsonElement Value)>();
            if (root.TryGetProperty("rateLimitsByLimitId", out var map) && map.ValueKind == JsonValueKind.Object)
                buckets.AddRange(map.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal)
                    .Select(p => (p.Name, p.Value)));
            var hasFallback = root.TryGetProperty("rateLimits", out var fallback) && fallback.ValueKind == JsonValueKind.Object;
            if (buckets.Count == 0 && hasFallback)
                buckets.Add((Text(fallback, "limitId") ?? "codex", fallback));
            if (buckets.Count == 0) throw new JsonException();
            var plan = hasFallback ? Text(fallback, "planType") : null;
            var windows = new List<QuotaDisplayWindow>();
            foreach (var (id, bucket) in buckets)
            {
                if (bucket.ValueKind != JsonValueKind.Object) throw new JsonException();
                plan ??= Text(bucket, "planType");
                foreach (var slot in new[] { "primary", "secondary" })
                {
                    if (!bucket.TryGetProperty(slot, out var value) || value.ValueKind == JsonValueKind.Null) continue;
                    if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty("usedPercent", out var used) ||
                        !used.TryGetDouble(out var percent) || !double.IsFinite(percent)) throw new JsonException();
                    int? duration = value.TryGetProperty("windowDurationMins", out var minutes) && minutes.TryGetInt32(out var count) ? count : null;
                    DateTimeOffset? reset = null;
                    if (value.TryGetProperty("resetsAt", out var resets) && resets.ValueKind != JsonValueKind.Null)
                    {
                        if (!resets.TryGetInt64(out var seconds)) throw new JsonException();
                        reset = DateTimeOffset.FromUnixTimeSeconds(seconds);
                    }
                    var name = Text(bucket, "limitName") ?? (id == "codex" ? "Codex" : id);
                    var label = duration switch
                    {
                        10080 => "每周额度", 1440 => "每日额度",
                        > 0 when duration % 60 == 0 => $"{duration / 60} 小时额度",
                        > 0 => $"{duration} 分钟额度", _ => slot == "primary" ? "主额度" : "次额度"
                    };
                    windows.Add(new($"{id}/{slot}", $"{name} · {label}", percent, duration, reset));
                }
            }
            bool? allowed = root.TryGetProperty("ordinaryUsageAllowed", out var permission) &&
                permission.ValueKind is JsonValueKind.True or JsonValueKind.False ? permission.GetBoolean() : null;
            var planName = string.IsNullOrWhiteSpace(plan) ? "套餐未知" : CultureInfo.InvariantCulture.TextInfo.ToTitleCase(plan.Replace('_', ' '));
            return new(Text(root, "accountId"), allowed, planName, windows);
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or ArgumentOutOfRangeException)
        {
            throw new CodexReadException(CodexReadError.InvalidResponse);
        }
    }

    private static string? Text(JsonElement parent, string key) => parent.TryGetProperty(key, out var value) &&
        value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}

public sealed record RecoveryEvent(string Id, string Title, string Body);
public sealed record QuotaCheckpoint(double UsedPercent, int? DurationMinutes);

public sealed class ResetDetectorState
{
    public string? AccountId { get; set; }
    public bool? LastPermission { get; set; }
    public Dictionary<string, QuotaCheckpoint> Checkpoints { get; set; } = [];
    public string? LastEventFingerprint { get; set; }
    public DateTimeOffset? LastEventAt { get; set; }
    public UsageSnapshot? LastGoodSnapshot { get; set; }
    public DateTimeOffset? LastObservedAt { get; set; }
}

public sealed class ResetDetector(ResetDetectorState? state = null)
{
    public ResetDetectorState State { get; private set; } = state ?? new();

    public IReadOnlyList<RecoveryEvent> Ingest(UsageSnapshot snapshot, DateTimeOffset now)
    {
        if (string.IsNullOrWhiteSpace(snapshot.AccountId)) { State = new(); return []; }
        if (State.AccountId != snapshot.AccountId)
        {
            State = new() { AccountId = snapshot.AccountId };
            Record(snapshot, now);
            return [];
        }
        if (snapshot.OrdinaryUsageAllowed is not bool allowed) return [];
        var permissionRecovered = State.LastPermission == false && allowed;
        var restored = snapshot.Windows.Where(window => State.Checkpoints.TryGetValue(window.Id, out var old) &&
            old.DurationMinutes == window.DurationMinutes && window.RemainingPercent - Math.Clamp(100 - old.UsedPercent, 0, 100) >= 1).ToList();
        var details = restored.Select(window => $"{window.Title}：剩余 {Percent(Math.Clamp(100 - State.Checkpoints[window.Id].UsedPercent, 0, 100))} → {Percent(window.RemainingPercent)}").ToArray();
        Record(snapshot, now);
        if (!allowed || (!permissionRecovered && restored.Count == 0)) return [];
        var body = details.Length == 0 ? "Codex 已确认普通额度恢复可用。" : string.Join('\n', details);
        var fingerprint = $"{permissionRecovered}|{body}|{string.Join('|', restored.Select(w => $"{w.Id}:{w.ResetsAt?.ToUnixTimeSeconds()}"))}";
        if (!permissionRecovered && State.LastEventFingerprint == fingerprint && State.LastEventAt is { } previous &&
            now >= previous && now - previous < TimeSpan.FromMinutes(5)) return [];
        State.LastEventFingerprint = fingerprint;
        State.LastEventAt = now;
        return [new(Guid.NewGuid().ToString(), "Codex 额度已恢复", body)];
    }

    private void Record(UsageSnapshot snapshot, DateTimeOffset now)
    {
        if (snapshot.OrdinaryUsageAllowed is not bool permission) return;
        State.LastPermission = permission;
        State.Checkpoints = snapshot.Windows.ToDictionary(w => w.Id, w => new QuotaCheckpoint(w.UsedPercent, w.DurationMinutes));
        State.LastGoodSnapshot = snapshot;
        State.LastObservedAt = now;
    }

    internal static string Percent(double value) => value.ToString("0.#", CultureInfo.InvariantCulture) + "%";
}
