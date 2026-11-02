using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace CodexResetBar.Core;

public enum CodexReadError { NotFound, InvalidPath, LaunchFailed, TimedOut, Disconnected, LoginRequired, RequestFailed, InvalidResponse }

public sealed class CodexReadException(CodexReadError code) : Exception(code switch
{
    CodexReadError.NotFound => "找不到本机 Codex CLI，请先安装，或在设置中选择 codex.exe / codex.cmd。",
    CodexReadError.InvalidPath => "CLI 路径无效。请选择本机已存在的 codex.exe 或 codex.cmd 绝对路径。",
    CodexReadError.LaunchFailed => "无法启动 Codex 额度查询服务，请检查 CLI 路径和安装状态。",
    CodexReadError.TimedOut => "额度查询超时，将在下次自动刷新时重试。",
    CodexReadError.Disconnected => "Codex 额度查询服务已断开，将自动重试。",
    CodexReadError.LoginRequired => "请打开 Codex，确认已登录 ChatGPT 账号。",
    CodexReadError.RequestFailed => "暂时无法取得额度，请检查网络和 Codex 登录状态。",
    _ => "Codex 返回了无法识别的额度数据，请更新 Codex 后重试。"
})
{
    public CodexReadError Code { get; } = code;
}

public static class CodexLocator
{
    public static string Resolve(string? configuredCliPath = null)
    {
        if (!string.IsNullOrWhiteSpace(configuredCliPath)) return Validate(configuredCliPath.Trim());
        var directories = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Select(p => p.Trim().Trim('"')).Where(p => p.Length > 0).ToList();
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        directories.AddRange(new[] { Path.Combine(local, "Microsoft", "WindowsApps"),
            Path.Combine(local, "Programs", "Codex"), Path.Combine(roaming, "npm") });
        var candidates = new List<string>();
        foreach (var directory in directories)
        {
            candidates.Add(Path.Combine(directory, "codex.exe"));
            foreach (var target in new[] { "x86_64-pc-windows-msvc", "aarch64-pc-windows-msvc" })
                candidates.Add(Path.Combine(directory, "node_modules", "@openai", "codex", "vendor", target, "codex", "codex.exe"));
        }
        // The newer npm package stores the native CLI in an optional platform package.
        foreach (var directory in directories)
            foreach (var architecture in new[] { "x64", "arm64" })
                foreach (var target in new[] { "x86_64-pc-windows-msvc", "aarch64-pc-windows-msvc" })
                    candidates.Add(Path.Combine(directory, "node_modules", "@openai", "codex", "node_modules", "@openai",
                        $"codex-win32-{architecture}", "vendor", target, "codex", "codex.exe"));
        candidates.AddRange(directories.Select(directory => Path.Combine(directory, "codex.cmd")));
        foreach (var candidate in candidates.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!Path.IsPathFullyQualified(candidate) || !File.Exists(candidate)) continue;
            try { return Validate(candidate); } catch (CodexReadException) { }
        }
        throw new CodexReadException(CodexReadError.NotFound);
    }

    private static string Validate(string path)
    {
        if (!Path.IsPathFullyQualified(path) || !File.Exists(path)) throw new CodexReadException(CodexReadError.InvalidPath);
        var extension = Path.GetExtension(path);
        if (!extension.Equals(".exe", StringComparison.OrdinalIgnoreCase) && !extension.Equals(".cmd", StringComparison.OrdinalIgnoreCase))
            throw new CodexReadException(CodexReadError.InvalidPath);
        // cmd expands these even inside quotes; refuse them instead of attempting escaping.
        if (extension.Equals(".cmd", StringComparison.OrdinalIgnoreCase) && path.IndexOfAny(['"', '\r', '\n', '&', '|', '<', '>', '^', '%', '!']) >= 0)
            throw new CodexReadException(CodexReadError.InvalidPath);
        return Path.GetFullPath(path);
    }
}

public sealed class CodexClient
{
    public async Task<UsageSnapshot> FetchAsync(string? configuredCliPath = null, CancellationToken cancellationToken = default)
    {
        var executable = CodexLocator.Resolve(configuredCliPath);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(20));
        var token = deadline.Token;
        var start = new ProcessStartInfo
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = new UTF8Encoding(false),
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
        };
        if (Path.GetExtension(executable).Equals(".cmd", StringComparison.OrdinalIgnoreCase))
        {
            if (!OperatingSystem.IsWindows()) throw new CodexReadException(CodexReadError.LaunchFailed);
            start.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe");
            start.Arguments = $"/d /s /c \"\"{executable}\" app-server --stdio\"";
        }
        else
        {
            start.FileName = executable;
            start.ArgumentList.Add("app-server");
            start.ArgumentList.Add("--stdio");
        }
        using var process = new Process { StartInfo = start };
        Task? stderrDrain = null;
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            try { if (!process.Start()) throw new CodexReadException(CodexReadError.LaunchFailed); }
            catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
            { throw new CodexReadException(CodexReadError.LaunchFailed); }
            // Diagnostics may contain authentication/account information; discard without decoding or recording.
            stderrDrain = process.StandardError.BaseStream.CopyToAsync(Stream.Null, token);
            var reader = new RpcReader(process.StandardOutput);
            await SendAsync(process, new { id = 1, method = "initialize", @params = new
            {
                clientInfo = new { name = "codex_reset_bar", title = "Codex 额度提醒", version = "1.5.0" },
                capabilities = new { experimentalApi = false, requestAttestation = false }
            } }, token);
            _ = await reader.ResponseAsync(1, token);
            await SendAsync(process, new { method = "initialized", @params = new { } }, token);
            await SendAsync(process, new { id = 2, method = "account/rateLimits/read", @params = new { excludeResetCreditDetails = true } }, token);
            return QuotaParser.Parse(await reader.ResponseAsync(2, token));
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { throw new CodexReadException(CodexReadError.TimedOut); }
        catch (Exception error) when (error is IOException or ObjectDisposedException)
        { throw new CodexReadException(CodexReadError.Disconnected); }
        finally
        {
            try { process.StandardInput.Close(); }
            catch (Exception error) when (error is InvalidOperationException or IOException or ObjectDisposedException) { }
            try
            {
                // Kill only the service started by this invocation and its own descendants.
                if (!process.HasExited) process.Kill(entireProcessTree: true);
                await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2));
            }
            catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception or TimeoutException) { }
            deadline.Cancel();
            if (stderrDrain != null)
                try { await stderrDrain; } catch (Exception error) when (error is IOException or OperationCanceledException or ObjectDisposedException) { }
        }
    }

    private static async Task SendAsync(Process process, object request, CancellationToken token)
    {
        await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(request).AsMemory(), token);
        await process.StandardInput.FlushAsync(token);
    }

    private sealed class RpcReader(StreamReader reader)
    {
        private readonly StringBuilder pending = new();
        private readonly char[] chunk = new char[4096];
        private const int MaximumBufferedCharacters = 8 * 1024 * 1024;

        public async Task<string> ResponseAsync(int id, CancellationToken token)
        {
            while (true)
            {
                while (TryLine(out var line))
                {
                    JsonDocument document;
                    try { document = JsonDocument.Parse(line); } catch (JsonException) { continue; }
                    using (document)
                    {
                        var root = document.RootElement;
                        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("id", out var responseId) ||
                            responseId.ValueKind != JsonValueKind.Number || !responseId.TryGetInt32(out var actualId) || actualId != id) continue;
                        if (root.TryGetProperty("error", out var error))
                        {
                            var message = error.ValueKind == JsonValueKind.Object && error.TryGetProperty("message", out var text) && text.ValueKind == JsonValueKind.String
                                ? text.GetString()?.ToLowerInvariant() ?? "" : "";
                            var auth = new[] { "auth", "log in", "login", "401" }.Any(message.Contains);
                            throw new CodexReadException(auth ? CodexReadError.LoginRequired : CodexReadError.RequestFailed);
                        }
                        if (!root.TryGetProperty("result", out var result) || result.ValueKind != JsonValueKind.Object)
                            throw new CodexReadException(CodexReadError.InvalidResponse);
                        return result.GetRawText();
                    }
                }
                var count = await reader.ReadAsync(chunk.AsMemory(), token);
                if (count == 0) throw new CodexReadException(CodexReadError.Disconnected);
                pending.Append(chunk, 0, count);
                if (pending.Length > MaximumBufferedCharacters) throw new CodexReadException(CodexReadError.InvalidResponse);
            }
        }

        private bool TryLine(out string line)
        {
            for (var i = 0; i < pending.Length; i++)
                if (pending[i] == '\n')
                {
                    line = pending.ToString(0, i);
                    pending.Remove(0, i + 1);
                    return true;
                }
            line = "";
            return false;
        }
    }
}
