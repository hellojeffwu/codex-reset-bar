using System.Globalization;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;

namespace CodexResetBar.Core;

public sealed class BarkMessage
{
    public const string DefaultTitle = "Codex 额度已恢复";
    public const string DefaultBody = "电脑检测到 Codex 额度恢复，请打开 Codex 查看。";
    public string Title { get; }
    public string Body { get; }

    public BarkMessage(string title = DefaultTitle, string body = DefaultBody)
    {
        Title = string.IsNullOrWhiteSpace(title) ? DefaultTitle : title.Trim();
        Body = string.IsNullOrWhiteSpace(body) ? DefaultBody : body.Trim();
        if (new StringInfo(Title).LengthInTextElements > 100 || new StringInfo(Body).LengthInTextElements > 500 ||
            Encoding.UTF8.GetByteCount(Title) + Encoding.UTF8.GetByteCount(Body) > 2500)
            throw new ArgumentException("推送内容太长：标题最多 100 字，正文最多 500 字；过多表情请适当减少。");
    }
}

public enum BarkPushResult { Accepted, Rejected, InvalidResponse, NetworkError, TimedOut }

public sealed class BarkClient : IDisposable
{
    private readonly HttpClient client;

    public BarkClient() : this(new HttpClientHandler { AllowAutoRedirect = false }) { }

    // Handler injection supports offline protocol tests; the public endpoint remains fixed.
    public BarkClient(HttpMessageHandler handler)
    {
        client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
    }

    public static string ParseDeviceKey(string addressOrKey)
    {
        var value = addressOrKey.Trim();
        var key = value;
        if (value.Contains("://", StringComparison.Ordinal))
        {
            var authority = value[(value.IndexOf("://", StringComparison.Ordinal) + 3)..].Split('/', '?', '#')[0];
            if (!Uri.TryCreate(value, UriKind.Absolute, out var url) || url.Scheme != "https" ||
                !url.Host.Equals("api.day.app", StringComparison.OrdinalIgnoreCase) || !url.IsDefaultPort ||
                !string.IsNullOrEmpty(url.UserInfo) || authority.Contains(':')) throw InvalidKey();
            var first = url.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
            if (first == null) throw InvalidKey();
            key = Uri.UnescapeDataString(first);
        }
        if (key.Length is 0 or > 256 || key.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('_' or '-')) ||
            new[] { "push", "ping", "healthz", "info", "mcp" }.Contains(key.ToLowerInvariant())) throw InvalidKey();
        return key;
    }

    public async Task<BarkPushResult> SendAsync(string deviceKey, BarkMessage message, bool test = false, CancellationToken cancellationToken = default)
    {
        var key = ParseDeviceKey(deviceKey);
        // Test suffix/prefix must fit the same final-message limits.
        var final = test ? new BarkMessage($"【测试】{message.Title}", $"{message.Body}\n\n（测试通知，当前额度未发生变化。）") : message;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(20));
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.day.app/push")
            {
                Content = JsonContent.Create(new
                {
                    device_key = key, title = final.Title, body = final.Body,
                    group = "Codex", level = "timeSensitive", sound = "alarm", call = "1"
                })
            };
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            if (!response.IsSuccessStatusCode) return BarkPushResult.Rejected;
            await using var stream = await response.Content.ReadAsStreamAsync(deadline.Token);
            using var body = new MemoryStream();
            var buffer = new byte[4096];
            while (true)
            {
                var count = await stream.ReadAsync(buffer, deadline.Token);
                if (count == 0) break;
                if (body.Length + count > 64 * 1024) return BarkPushResult.InvalidResponse;
                body.Write(buffer, 0, count);
            }
            using var json = JsonDocument.Parse(body.ToArray());
            var root = json.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("code", out var code) ||
                code.ValueKind != JsonValueKind.Number || !code.TryGetInt32(out var number)) return BarkPushResult.InvalidResponse;
            return number == 200 ? BarkPushResult.Accepted : BarkPushResult.Rejected;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { return BarkPushResult.TimedOut; }
        catch (JsonException) { return BarkPushResult.InvalidResponse; }
        catch (Exception error) when (error is HttpRequestException or IOException) { return BarkPushResult.NetworkError; }
    }

    private static ArgumentException InvalidKey() => new("请粘贴 Bark 首页的 https://api.day.app/… 地址或设备 Key。");
    public void Dispose() => client.Dispose();
}
