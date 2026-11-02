# Windows Core interface (net10.0, no NuGet packages)

Namespace: `CodexResetBar.Core`. All dates are `DateTimeOffset`; properties use PascalCase. All APIs below are implemented in this project. UI owns timer cadence, serialization, DPAPI, user notifications, sound and startup.

```csharp
var client = new CodexClient();
UsageSnapshot snapshot = await client.FetchAsync(configuredCliPath, cancellationToken);
var reset = new ResetDetector(savedResetState); // optional state, null on first run
IReadOnlyList<RecoveryEvent> recovered = reset.Ingest(snapshot, DateTimeOffset.Now);
var nodes = new NodeDetector(savedNodeState);
IReadOnlyList<ReminderEvent> events = nodes.Ingest(snapshot, rules, DateTimeOffset.Now);
// On failed quota reads / clock ticks pass null, never pass a cached snapshot.
events = nodes.Ingest(null, rules, DateTimeOffset.Now);
var tasks = new TaskActivityMonitor(); // default ~/.codex/sessions; keep one instance
foreach (TaskSignal signal in await tasks.PollAsync(cancellationToken))
    events = ReminderEvaluator.ForTaskSignal(signal, rules);
```

- `UsageSnapshot`: `string? AccountId`, `bool? OrdinaryUsageAllowed`, `string PlanName`, `IReadOnlyList<QuotaDisplayWindow> Windows`. Constructor takes these four in that order.
- `QuotaDisplayWindow`: `(string Id, string Title, double UsedPercent, int? DurationMinutes, DateTimeOffset? ResetsAt)`, computed `double RemainingPercent`.
- `QuotaParser.Parse(string json)` parses the *result object* of account/rateLimits/read. It prefers nonempty rateLimitsByLimitId over rateLimits. Invalid data throws `CodexReadException`.
- `CodexClient.FetchAsync(string? configuredCliPath = null, CancellationToken cancellationToken = default)`; `CodexLocator.Resolve(string? configuredCliPath = null)` returns absolute CLI path or throws `CodexReadException`. A configured path must be an existing absolute `.exe`/`.cmd`. Native `.exe` discovery precedes `.cmd`. `.cmd` uses system cmd.exe with a strictly validated discovered absolute path.
- `CodexReadException`: `Code` (`CodexReadError`: `NotFound`, `InvalidPath`, `LaunchFailed`, `TimedOut`, `Disconnected`, `LoginRequired`, `RequestFailed`, `InvalidResponse`) and safe Chinese `Message`. Cancellation from the caller throws `OperationCanceledException`.
- `RecoveryEvent`: `(string Id, string Title, string Body)`. Reset detector defaults title/body; UI may replace with its configured reset title/body. `ResetDetector.State` is a JSON-serializable `ResetDetectorState`; pass saved state to constructor. First observation/account changes are silent. Unknown permission does not advance a known checkpoint.
- `ReminderKind`: `QuotaBelow`, `ResetSoon`, `Scheduled`, `TaskCompleted`, `TaskFailed`, `TaskNeedsInput`.
- `ReminderRule`: mutable record properties `Id` string; `Kind`; `Enabled` bool; `Threshold` int; `MinutesBeforeReset` int; `ScheduledAt` DateTimeOffset; `Title`, `Body` string; `Sound`, `Popup`, `Phone` bool. `ReminderRule.Create(kind)` creates a default; `ReminderRule.Presets` returns defaults (20%, 10%, 10min before reset, completed, failed disabled, needs-input). Max 30 rules. `ReminderRule.Validate(rules)` throws `ArgumentException` for invalid count/IDs/values/messages.
- `ReminderEvent`: `(string Id, string RuleId, string Title, string Body, bool Sound, bool Popup, bool Phone)`. Details append to configured Body.
- `NodeDetector.State` is JSON-serializable `NodeDetectorState`, optional constructor argument. First observation, changed rule and account changes establish a silent quota baseline. Scheduled dates already past when first seen never fire. A configured future scheduled date fires once. Expected-reset alerts require a fresh snapshot crossing into the lead interval and never represent actual recovery.
- `TaskSignalKind`: `Completed`, `Failed`, `NeedsInput`. `TaskSignal`: `(string Id, TaskSignalKind Kind, string Detail, DateTimeOffset Date)`. `TaskActivityMonitor(string? root = null, DateTimeOffset? startedAt = null)` and `Task<IReadOnlyList<TaskSignal>> PollAsync(CancellationToken cancellationToken = default)`. First poll starts each existing file at EOF. Metadata is read without replaying old task events. No chat text/tool arguments/tool output enters notifications. Failure is at most once per explicit turn. Subagents, killed commands and search-no-results are excluded.
- `ReminderEvaluator.ForTaskSignal(TaskSignal, IReadOnlyList<ReminderRule>)` returns events for enabled task rules. Monitor deduplicates source events; UI must call evaluator once per signal.
- `BarkMessage(string title = ..., string body = ...)` validates trimmed/fallback text: 100/500 Unicode text elements and combined UTF-8 <=2500 bytes. `Title`, `Body` read-only.
- `BarkClient.ParseDeviceKey(string addressOrKey)` returns a validated key. Do not log/store plaintext. `BarkClient.SendAsync(string deviceKey, BarkMessage message, bool test = false, CancellationToken cancellationToken = default)` returns `BarkPushResult`: `Accepted`, `Rejected`, `InvalidResponse`, `NetworkError`, `TimedOut`. Validation throws safe `ArgumentException`. Only official HTTPS JSON POST, no redirects, 20s timeout; Accepted requires HTTP 2xx and JSON integer code 200. Success means service acceptance, not confirmed handset delivery. Dispose the `BarkClient` when app exits.
- `CoreJson.Options` provides camelCase properties and string enums for state/rule persistence; use the same options to save/load. State contains quota/account identity and rule dedup only; sensitive Bark key storage belongs to UI.

Do not run a model turn, inspect auth files, display stderr, pass cached snapshots to detector as fresh data, or globally kill Codex. A failed read must retain the UI's last successful display and detector state.
