namespace CodexResetBar.Core;

public enum ReminderKind { QuotaBelow, ResetSoon, Scheduled, TaskCompleted, TaskFailed, TaskNeedsInput }

public sealed record ReminderRule
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public ReminderKind Kind { get; set; }
    public bool Enabled { get; set; } = true;
    public int Threshold { get; set; } = 20;
    public int MinutesBeforeReset { get; set; } = 10;
    public DateTimeOffset ScheduledAt { get; set; } = DateTimeOffset.Now.AddHours(1);
    public string Title { get; set; } = "";
    public string Body { get; set; } = "";
    public bool Sound { get; set; } = true;
    public bool Popup { get; set; } = true;
    public bool Phone { get; set; } = true;

    public static ReminderRule Create(ReminderKind kind)
    {
        var (title, body) = kind switch
        {
            ReminderKind.QuotaBelow => ("Codex 剩余额度偏低", "剩余额度已达到你设置的提醒阈值。"),
            ReminderKind.ResetSoon => ("Codex 接近预计重置时间", "这是预计时间提醒，额度是否恢复仍以实际检测为准。"),
            ReminderKind.Scheduled => ("Codex 定时提醒", "到你设置的提醒时间了。"),
            ReminderKind.TaskCompleted => ("Codex 这一轮已完成", "有一个 Codex 对话完成了这一轮工作，可以查看结果了。"),
            ReminderKind.TaskFailed => ("Codex 执行步骤报错", "有一个 Codex 执行步骤返回错误；这不代表整个任务失败。"),
            ReminderKind.TaskNeedsInput => ("Codex 任务有提问", "有一个 Codex 对话发出了需要你回答的问题，可以打开查看。"),
            _ => throw new ArgumentException("无法识别提醒类型。")
        };
        return new() { Kind = kind, Title = title, Body = body };
    }

    public static IReadOnlyList<ReminderRule> Presets
    {
        get
        {
            var rules = new[] { Create(ReminderKind.QuotaBelow), Create(ReminderKind.QuotaBelow), Create(ReminderKind.ResetSoon),
                Create(ReminderKind.TaskCompleted), Create(ReminderKind.TaskFailed), Create(ReminderKind.TaskNeedsInput) };
            rules[1].Threshold = 10;
            rules[4].Enabled = false;
            foreach (var rule in rules)
            {
                rule.ScheduledAt = DateTimeOffset.UnixEpoch;
                rule.Id = rule.Kind == ReminderKind.QuotaBelow ? $"preset.quota-below-{rule.Threshold}" : $"preset.{rule.Kind}";
            }
            return rules;
        }
    }

    public static void Validate(IReadOnlyList<ReminderRule> rules)
    {
        if (rules.Count > 30) throw new ArgumentException("最多可设置 30 个提醒节点。");
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var rule in rules)
        {
            if (string.IsNullOrWhiteSpace(rule.Id) || rule.Id.Length > 256 || !ids.Add(rule.Id))
                throw new ArgumentException("提醒节点 ID 为空或重复。");
            if (!Enum.IsDefined(rule.Kind) || rule.Threshold is < 0 or > 100 || rule.MinutesBeforeReset is < 1 or > 10080)
                throw new ArgumentException("提醒节点阈值或提前时间无效。");
            _ = new BarkMessage(rule.Title, rule.Body);
        }
    }
}

public sealed record ReminderEvent(string Id, string RuleId, string Title, string Body, bool Sound, bool Popup, bool Phone);

public sealed class NodeWindowState
{
    public double Remaining { get; set; }
    public int? Duration { get; set; }
    public bool Armed { get; set; }
    public DateTimeOffset? ResetAt { get; set; }
    public DateTimeOffset ObservedAt { get; set; }
    public List<DateTimeOffset> NotifiedResets { get; set; } = [];
}

public sealed class NodeRuleState
{
    public ReminderRule Rule { get; set; } = new();
    public Dictionary<string, NodeWindowState> Windows { get; set; } = [];
    public bool ScheduledPending { get; set; }
}

public sealed class NodeDetectorState
{
    public string? AccountId { get; set; }
    public Dictionary<string, NodeRuleState> Rules { get; set; } = [];
}

public sealed class NodeDetector(NodeDetectorState? state = null)
{
    public NodeDetectorState State { get; } = state ?? new();

    public IReadOnlyList<ReminderEvent> Ingest(UsageSnapshot? snapshot, IReadOnlyList<ReminderRule> rules, DateTimeOffset now)
    {
        ReminderRule.Validate(rules);
        var ids = rules.Select(r => r.Id).ToHashSet(StringComparer.Ordinal);
        foreach (var id in State.Rules.Keys.Where(id => !ids.Contains(id)).ToList()) State.Rules.Remove(id);
        if (snapshot != null)
        {
            var identity = string.IsNullOrWhiteSpace(snapshot.AccountId) ? null : snapshot.AccountId;
            if (State.AccountId != identity)
            {
                State.AccountId = identity;
                foreach (var rule in State.Rules.Values) rule.Windows.Clear();
            }
        }
        var events = new List<ReminderEvent>();
        foreach (var rule in rules)
        {
            if (rule.Kind is not (ReminderKind.QuotaBelow or ReminderKind.ResetSoon or ReminderKind.Scheduled))
            { State.Rules.Remove(rule.Id); continue; }
            if (!State.Rules.TryGetValue(rule.Id, out var current) || current.Rule != rule)
            {
                current = new() { Rule = rule with { }, ScheduledPending = rule.Enabled && rule.ScheduledAt > now };
                State.Rules[rule.Id] = current;
            }
            if (!rule.Enabled) continue;
            if (rule.Kind == ReminderKind.Scheduled)
            {
                if (current.ScheduledPending && now >= rule.ScheduledAt)
                {
                    current.ScheduledPending = false;
                    events.Add(ReminderEvaluator.MakeEvent(rule, $"设定时间：{rule.ScheduledAt:g}"));
                }
                continue;
            }
            if (snapshot == null || State.AccountId == null) continue;
            var details = new List<string>();
            var nextWindows = new Dictionary<string, NodeWindowState>();
            foreach (var window in snapshot.Windows)
            {
                if (rule.Kind == ReminderKind.ResetSoon && window.ResetsAt == null) continue;
                current.Windows.TryGetValue(window.Id, out var old);
                var next = new NodeWindowState
                {
                    Remaining = window.RemainingPercent, Duration = window.DurationMinutes,
                    Armed = window.RemainingPercent > rule.Threshold, ResetAt = window.ResetsAt, ObservedAt = now
                };
                if (old != null && old.Duration == window.DurationMinutes)
                {
                    next.Armed = old.Armed;
                    next.NotifiedResets = old.NotifiedResets.ToList();
                    if (rule.Kind == ReminderKind.QuotaBelow)
                    {
                        if (old.Armed && old.Remaining > rule.Threshold && window.RemainingPercent <= rule.Threshold)
                        {
                            details.Add($"{window.Title}：剩余 {ResetDetector.Percent(window.RemainingPercent)}（提醒阈值 {rule.Threshold}%）");
                            next.Armed = false;
                        }
                        else if (window.RemainingPercent >= rule.Threshold + 1) next.Armed = true;
                    }
                    else if (window.ResetsAt is { } resetAt && old.ResetAt == resetAt)
                    {
                        var lead = TimeSpan.FromMinutes(rule.MinutesBeforeReset);
                        var remaining = resetAt - now;
                        if (remaining > TimeSpan.Zero && remaining <= lead && resetAt - old.ObservedAt > lead &&
                            !old.NotifiedResets.Contains(resetAt))
                        {
                            details.Add($"{window.Title}：预计 {resetAt:g} 重置（约 {Math.Ceiling(remaining.TotalMinutes)} 分钟后）");
                            next.NotifiedResets = old.NotifiedResets.Append(resetAt).TakeLast(16).ToList();
                        }
                    }
                }
                nextWindows[window.Id] = next;
            }
            current.Windows = nextWindows;
            if (details.Count > 0) events.Add(ReminderEvaluator.MakeEvent(rule, string.Join('\n', details)));
        }
        return events;
    }
}

public static class ReminderEvaluator
{
    public static IReadOnlyList<ReminderEvent> ForTaskSignal(TaskSignal signal, IReadOnlyList<ReminderRule> rules)
    {
        ReminderRule.Validate(rules);
        var kind = signal.Kind switch
        {
            TaskSignalKind.Completed => ReminderKind.TaskCompleted,
            TaskSignalKind.Failed => ReminderKind.TaskFailed,
            _ => ReminderKind.TaskNeedsInput
        };
        return rules.Where(r => r.Enabled && r.Kind == kind).Select(r => MakeEvent(r, signal.Detail)).ToList();
    }

    internal static ReminderEvent MakeEvent(ReminderRule rule, string details)
    {
        var fallback = ReminderRule.Create(rule.Kind);
        return new(Guid.NewGuid().ToString(), rule.Id, string.IsNullOrWhiteSpace(rule.Title) ? fallback.Title : rule.Title,
            string.Join('\n', new[] { string.IsNullOrWhiteSpace(rule.Body) ? fallback.Body : rule.Body, details }.Where(s => s.Length > 0)),
            rule.Sound, rule.Popup, rule.Phone);
    }
}
