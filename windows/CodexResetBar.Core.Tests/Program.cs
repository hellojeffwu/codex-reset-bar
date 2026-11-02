using System.Net;
using System.Text;
using System.Text.Json;
using CodexResetBar.Core;

if (args.SequenceEqual(new[] { "app-server", "--stdio" }) && Environment.GetEnvironmentVariable("CBR_CORE_FIXTURE") == "1")
{
    using var initialize = JsonDocument.Parse((await Console.In.ReadLineAsync())!);
    if (initialize.RootElement.GetProperty("method").GetString() != "initialize") return 2;
    // A token-like diagnostic must never enter the parent app's result/error.
    Console.Error.WriteLine("FIXTURE_AUTH_DIAGNOSTIC_MUST_BE_DISCARDED");
    Console.WriteLine("{\"method\":\"fixture/notification\",\"params\":{}}");
    Console.WriteLine("{\"id\":1,\"result\":{}}");
    using var initialized = JsonDocument.Parse((await Console.In.ReadLineAsync())!);
    using var read = JsonDocument.Parse((await Console.In.ReadLineAsync())!);
    if (initialized.RootElement.GetProperty("method").GetString() != "initialized" ||
        read.RootElement.GetProperty("method").GetString() != "account/rateLimits/read" ||
        !read.RootElement.GetProperty("params").GetProperty("excludeResetCreditDetails").GetBoolean()) return 3;
    var mode = Environment.GetEnvironmentVariable("CBR_CORE_FIXTURE_MODE");
    if (mode == "disconnect") return 0;
    if (mode == "hang") { await Task.Delay(Timeout.Infinite); return 0; }
    if (mode == "login")
    {
        Console.WriteLine("{\"id\":2,\"error\":{\"message\":\"auth FIXTURE_PRIVATE_TOKEN\"}}");
        await Console.In.ReadLineAsync();
        return 0;
    }
    using var quota = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "quota-map.json")));
    Console.WriteLine(JsonSerializer.Serialize(new { id = 2, result = quota.RootElement }));
    // Remain alive until the client closes stdin; this also checks owned-child cleanup.
    await Console.In.ReadLineAsync();
    return 0;
}

var count = 0;
void Check(bool condition, string name)
{
    if (!condition) throw new Exception("FAIL: " + name);
    count++;
    Console.WriteLine("PASS " + name);
}
void Reject(Action action, string name)
{
    try { action(); } catch (ArgumentException) { Check(true, name); return; }
    throw new Exception("FAIL: " + name);
}
T Roundtrip<T>(T value) => JsonSerializer.Deserialize<T>(JsonSerializer.Serialize(value, CoreJson.Options), CoreJson.Options)!;
var now = new DateTimeOffset(2026, 11, 2, 12, 0, 0, TimeSpan.Zero);
UsageSnapshot Snapshot(double remaining, bool? allowed = true, string? account = "A", DateTimeOffset? reset = null, int duration = 300) =>
    new(account, allowed, "Plus", [new("codex/primary", "Codex · 5 小时额度", 100 - remaining, duration, reset)]);

var mapped = QuotaParser.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "quota-map.json")));
Check(mapped.Windows.Count == 2 && mapped.Windows[0].RemainingPercent == 27.5 && mapped.PlanName == "Plus", "map priority and 100-usedPercent");
var fallback = QuotaParser.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "quota-fallback.json")));
Check(fallback.Windows.Count == 1 && fallback.Windows[0].RemainingPercent == 0 && fallback.OrdinaryUsageAllowed == false, "empty map falls back");
try { QuotaParser.Parse("{\"rateLimits\":{\"primary\":{\"usedPercent\":\"wrong\"}}}"); throw new Exception("invalid quota accepted"); }
catch (CodexReadException error) { Check(error.Code == CodexReadError.InvalidResponse, "safe invalid quota response"); }

var reset = new ResetDetector();
Check(reset.Ingest(Snapshot(10), now).Count == 0, "reset first sample silent");
Check(reset.Ingest(Snapshot(10.9), now.AddSeconds(1)).Count == 0, "sub-1pp improvement silent");
Check(reset.Ingest(Snapshot(12), now.AddSeconds(2)).Count == 1, "actual 1pp improvement notifies");
Check(reset.Ingest(Snapshot(12), now.AddSeconds(3)).Count == 0, "unchanged quota silent");
Check(reset.Ingest(Snapshot(99, account: "B"), now.AddSeconds(4)).Count == 0, "account switch baseline");
Check(reset.Ingest(Snapshot(0, false, "B"), now.AddSeconds(5)).Count == 0, "exhausted no recovery");
Check(reset.Ingest(Snapshot(99, null, "B"), now.AddSeconds(6)).Count == 0, "unknown permission silent");
reset = new ResetDetector(Roundtrip(reset.State));
Check(reset.Ingest(Snapshot(0, true, "B"), now.AddSeconds(7)).Count == 1, "permission recovery persists across unknown and reload");
Check(reset.Ingest(Snapshot(50, false, "B"), now.AddSeconds(8)).Count == 0, "improvement while disallowed silent");
Check(reset.Ingest(Snapshot(80, true, null), now.AddSeconds(9)).Count == 0 && reset.State.AccountId == null, "missing account clears baseline");
reset.Ingest(Snapshot(10), now);
Check(reset.Ingest(Snapshot(80, duration: 10080), now.AddSeconds(10)).Count == 0, "duration change baseline");
var duplicateReset = new ResetDetector();
duplicateReset.Ingest(Snapshot(10), now);
Check(duplicateReset.Ingest(Snapshot(20), now.AddSeconds(1)).Count == 1, "reset establishes dedup fingerprint");
duplicateReset.Ingest(Snapshot(10), now.AddSeconds(2));
duplicateReset = new ResetDetector(Roundtrip(duplicateReset.State));
Check(duplicateReset.Ingest(Snapshot(20), now.AddSeconds(3)).Count == 0, "reset duplicate suppressed after reload");

var low = ReminderRule.Create(ReminderKind.QuotaBelow) with { Threshold = 20, Sound = false, Phone = false, Title = "自定义标题", Body = "自定义正文" };
var node = new NodeDetector();
Check(node.Ingest(Snapshot(10), [low], now).Count == 0, "low quota no historical alert");
node.Ingest(Snapshot(30), [low], now.AddSeconds(1));
var events = node.Ingest(Snapshot(20), [low], now.AddSeconds(2));
Check(events.Count == 1 && events[0].Title == low.Title && events[0].Body.StartsWith(low.Body) && !events[0].Sound && !events[0].Phone, "threshold crossing custom content and channels");
node = new NodeDetector(Roundtrip(node.State));
Check(node.Ingest(Snapshot(19), [low], now.AddSeconds(3)).Count == 0, "low quota dedup reload");
Check(node.Ingest(Snapshot(90, account: "B"), [low], now.AddSeconds(4)).Count == 0, "node account baseline");
Check(node.Ingest(Snapshot(19, account: "B"), [low with { Body = "修改正文" }], now.AddSeconds(5)).Count == 0, "edited rule baseline");
Check(node.Ingest(null, [low], now.AddSeconds(6)).Count == 0, "clock tick cannot replay cached quota");

var soon = ReminderRule.Create(ReminderKind.ResetSoon) with { MinutesBeforeReset = 10 };
var resetAt = now.AddMinutes(20);
node = new NodeDetector();
node.Ingest(Snapshot(20, reset: resetAt), [soon], now);
Check(node.Ingest(null, [soon], now.AddMinutes(12)).Count == 0, "expected reset requires fresh quota");
Check(node.Ingest(Snapshot(20, reset: resetAt), [soon], now.AddMinutes(12)).Count == 1, "expected reset crossing");
node = new NodeDetector(Roundtrip(node.State));
Check(node.Ingest(Snapshot(20, reset: resetAt), [soon], now.AddMinutes(13)).Count == 0, "expected reset once after reload");
Check(node.Ingest(Snapshot(20, reset: resetAt), [soon], now.AddMinutes(21)).Count == 0, "past reset never claims recovery");
var schedule = ReminderRule.Create(ReminderKind.Scheduled) with { ScheduledAt = now.AddMinutes(5) };
node = new NodeDetector();
Check(node.Ingest(null, [schedule], now).Count == 0, "schedule armed future");
node = new NodeDetector(Roundtrip(node.State));
Check(node.Ingest(null, [schedule], now.AddMinutes(6)).Count == 1, "schedule fires after reload");
Check(new NodeDetector(Roundtrip(node.State)).Ingest(null, [schedule], now.AddMinutes(7)).Count == 0, "schedule one-shot persists");
Check(new NodeDetector().Ingest(null, [schedule], now.AddMinutes(8)).Count == 0, "past schedule no historical alert");
Reject(() => ReminderRule.Validate(Enumerable.Range(0, 31).Select(_ => ReminderRule.Create(ReminderKind.QuotaBelow)).ToArray()), "30-rule maximum");
Reject(() => ReminderRule.Validate([low, low]), "duplicate rule ids rejected");

Check(BarkClient.ParseDeviceKey("https://api.day.app/Fixture_Key-123/title/body") == "Fixture_Key-123", "Bark official address parsing");
foreach (var bad in new[] { "http://api.day.app/abc", "https://evil.example/abc", "https://api.day.app:443/abc", "https://x@api.day.app/abc", "https://api.day.app/a%2fb", "https://api.day.app/push", "bad key" })
    Reject(() => BarkClient.ParseDeviceKey(bad), "reject unsafe Bark address");
Reject(() => _ = new BarkMessage(new string('a', 101), "ok"), "title limit");
Reject(() => _ = new BarkMessage("ok", new string('a', 501)), "body limit");
Reject(() => _ = new BarkMessage(string.Concat(Enumerable.Repeat("👨‍👩‍👧‍👦", 100)), "ok"), "UTF8 total limit");
var handler = new FixtureHandler(HttpStatusCode.OK, "{\"code\":200}");
using (var bark = new BarkClient(handler))
{
    Check(await bark.SendAsync("FixtureKey", new BarkMessage("标题", "正文")) == BarkPushResult.Accepted, "Bark accepted only validated response");
    Check(handler.LastMethod == HttpMethod.Post && handler.LastUri == "https://api.day.app/push" &&
        handler.LastBody?.Contains("device_key") == true && handler.LastContentType?.StartsWith("application/json") == true, "Bark fixed POST JSON request");
}
foreach (var sample in new[] { (HttpStatusCode.Found, "{\"code\":200}", BarkPushResult.Rejected),
    (HttpStatusCode.OK, "{\"code\":400}", BarkPushResult.Rejected), (HttpStatusCode.OK, "{\"code\":\"200\"}", BarkPushResult.InvalidResponse),
    (HttpStatusCode.OK, "malformed", BarkPushResult.InvalidResponse) })
{
    using var bark = new BarkClient(new FixtureHandler(sample.Item1, sample.Item2));
    Check(await bark.SendAsync("FixtureKey", new BarkMessage()) == sample.Item3, "Bark rejects redirect/error/malformed");
}

var directory = Path.Combine(Path.GetTempPath(), "codex-reset-core-" + Guid.NewGuid());
Directory.CreateDirectory(directory);
try
{
    var main = Path.Combine(directory, "main.jsonl");
    var subagent = Path.Combine(directory, "subagent.jsonl");
    File.Copy(Path.Combine(AppContext.BaseDirectory, "Fixtures", "main-session.jsonl"), main);
    File.Copy(Path.Combine(AppContext.BaseDirectory, "Fixtures", "subagent-session.jsonl"), subagent);
    var monitor = new TaskActivityMonitor(directory, now);
    Check((await monitor.PollAsync()).Count == 0, "session first EOF ignores history");
    string Row(string type, object payload) => JsonSerializer.Serialize(new { timestamp = now.AddMinutes(1).ToString("O"), type, payload }) + "\n";
    async Task Append(string value) => await File.AppendAllTextAsync(main, value, new UTF8Encoding(false));
    await Append(Row("event_msg", new { type = "task_started", turn_id = "turn-1" }));
    var complete = Row("event_msg", new { type = "task_complete", turn_id = "turn-1" });
    await Append(complete[..^2]);
    Check((await monitor.PollAsync()).Count == 0, "partial JSON line retained");
    await Append(complete[^2..]);
    var signals = await monitor.PollAsync();
    Check(signals.Count == 1 && signals[0].Kind == TaskSignalKind.Completed, "completed only after newline");
    await Append(complete);
    Check((await monitor.PollAsync()).Count == 0, "task duplicate suppressed");
    await File.AppendAllTextAsync(subagent, complete);
    Check((await monitor.PollAsync()).Count == 0, "subagent excluded");
    await Append(Row("response_item", new { type = "function_call", name = "functions.request_user_input_async", call_id = "call-1", arguments = "PRIVATE QUESTION CONTENT" }));
    signals = await monitor.PollAsync();
    Check(signals.Count == 1 && signals[0].Kind == TaskSignalKind.NeedsInput && !signals[0].Detail.Contains("PRIVATE"), "explicit input signal without arguments");
    object Failure(string id, int exit, object[] parsed) => new { type = "item_completed", item = new { type = "CommandExecution", id, status = "failed", exit_code = exit, parsed_cmd = parsed } };
    await Append(Row("event_msg", Failure("search", 1, [new { type = "search" }])));
    await Append(Row("event_msg", Failure("killed", 130, [])));
    Check((await monitor.PollAsync()).Count == 0, "search no-result and interruption excluded");
    await Append(Row("event_msg", Failure("error1", 2, [])));
    await Append(Row("event_msg", Failure("error2", 2, [])));
    signals = await monitor.PollAsync();
    Check(signals.Count == 1 && signals[0].Kind == TaskSignalKind.Failed, "at most one error per turn");
    await Append(Row("event_msg", new { type = "task_started", turn_id = "turn-2" }));
    await Append(Row("event_msg", Failure("error3", 2, [])));
    Check((await monitor.PollAsync()).Count == 1, "explicit next turn rearms failure");
    await Append(Row("response_item", new { type = "message", role = "assistant", content = "All done / failed / please answer" }));
    Check((await monitor.PollAsync()).Count == 0, "chat words do not imply task status");
    Check(ReminderEvaluator.ForTaskSignal(new("x", TaskSignalKind.Failed, "details", now), ReminderRule.Presets).Count == 0, "failure preset disabled");
    var taskRule = ReminderRule.Create(ReminderKind.TaskCompleted) with { Popup = false };
    Check(ReminderEvaluator.ForTaskSignal(new("x", TaskSignalKind.Completed, "details", now), [taskRule]) is [{ Popup: false }], "task rule channels");
    var partial = Path.Combine(directory, "partial.jsonl");
    await File.WriteAllTextAsync(partial, File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "main-session.jsonl")) + complete[..^2]);
    var secondMonitor = new TaskActivityMonitor(directory, now);
    await secondMonitor.PollAsync();
    await File.AppendAllTextAsync(partial, complete[^2..]);
    Check((await secondMonitor.PollAsync()).Count == 0, "startup incomplete historical line discarded");

    var executable = Environment.ProcessPath!;
    if (Path.GetFileNameWithoutExtension(executable) != "dotnet")
    {
        var fixtureExe = Path.Combine(AppContext.BaseDirectory, "FixtureCodex.exe");
        File.Copy(executable, fixtureExe, true);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(fixtureExe, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var prior = Environment.GetEnvironmentVariable("CBR_CORE_FIXTURE");
        try
        {
            Environment.SetEnvironmentVariable("CBR_CORE_FIXTURE", "1");
            var client = new CodexClient();
            var fromProcess = await client.FetchAsync(fixtureExe);
            Check(fromProcess.Windows.Count == 2 && fromProcess.Windows[0].RemainingPercent == 27.5, "real child-process JSON-RPC handshake with fixture server");
            try
            {
                Environment.SetEnvironmentVariable("CBR_CORE_FIXTURE_MODE", "login");
                try { await client.FetchAsync(fixtureExe); throw new Exception("login error ignored"); }
                catch (CodexReadException error) { Check(error.Code == CodexReadError.LoginRequired && !error.Message.Contains("PRIVATE"), "protocol auth error safely classified"); }
                Environment.SetEnvironmentVariable("CBR_CORE_FIXTURE_MODE", "disconnect");
                try { await client.FetchAsync(fixtureExe); throw new Exception("disconnect ignored"); }
                catch (CodexReadException error) { Check(error.Code == CodexReadError.Disconnected, "protocol disconnect classified"); }
                Environment.SetEnvironmentVariable("CBR_CORE_FIXTURE_MODE", "hang");
                using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
                try { await client.FetchAsync(fixtureExe, cancellation.Token); throw new Exception("cancellation ignored"); }
                catch (OperationCanceledException) { Check(cancellation.IsCancellationRequested, "caller cancellation stops own child"); }
            }
            finally { Environment.SetEnvironmentVariable("CBR_CORE_FIXTURE_MODE", null); }
            if (OperatingSystem.IsWindows())
            {
                var fixtureCmd = Path.Combine(AppContext.BaseDirectory, "FixtureCodex.cmd");
                await File.WriteAllTextAsync(fixtureCmd, "@echo off\r\n\"%~dp0FixtureCodex.exe\" %*\r\n");
                try
                {
                    var fromCmd = await client.FetchAsync(fixtureCmd);
                    Check(fromCmd.Windows.Count == 2, "Windows cmd wrapper JSON-RPC handshake");
                }
                finally { File.Delete(fixtureCmd); }
            }
        }
        finally { Environment.SetEnvironmentVariable("CBR_CORE_FIXTURE", prior); File.Delete(fixtureExe); }
    }
    else Console.WriteLine("SKIP child-process fixture (run apphost instead of dotnet dll)");
    var badCmd = Path.Combine(directory, "bad%path.cmd");
    await File.WriteAllTextAsync(badCmd, "fixture");
    try { CodexLocator.Resolve(badCmd); throw new Exception("unsafe cmd accepted"); }
    catch (CodexReadException error) { Check(error.Code == CodexReadError.InvalidPath, "cmd metacharacter path rejected"); }
    try { CodexLocator.Resolve("relative.exe"); throw new Exception("relative path accepted"); }
    catch (CodexReadException error) { Check(error.Code == CodexReadError.InvalidPath, "relative CLI path rejected"); }
}
finally { Directory.Delete(directory, true); }
Console.WriteLine($"PASS all {count} checks. Offline fixtures only; no model calls, real push, or native Windows UI validation.");
return 0;

sealed class FixtureHandler(HttpStatusCode status, string body) : HttpMessageHandler
{
    public HttpMethod? LastMethod;
    public string? LastUri;
    public string? LastBody;
    public string? LastContentType;
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
    {
        LastMethod = request.Method;
        LastUri = request.RequestUri?.AbsoluteUri;
        LastBody = request.Content == null ? null : await request.Content.ReadAsStringAsync(token);
        LastContentType = request.Content?.Headers.ContentType?.ToString();
        return new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    }
}
