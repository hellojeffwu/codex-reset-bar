using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using CodexResetBar.Core;
using Microsoft.Win32;

namespace CodexResetBar;

internal sealed class LocalState
{
    public string? CodexPath { get; set; }
    public bool Sound { get; set; } = true;
    public bool Popup { get; set; } = true;
    public bool PhoneEnabled { get; set; }
    // This property only ever contains a DPAPI CurrentUser ciphertext, never the Bark key.
    public string? ProtectedBarkKey { get; set; }
    public string PhoneTitle { get; set; } = "Codex 额度已恢复";
    public string PhoneBody { get; set; } = "电脑检测到 Codex 额度恢复，请打开 Codex 查看。";
    public List<ReminderRule> Rules { get; set; } = ReminderRule.Presets.ToList();
    public ResetDetectorState? ResetState { get; set; }
    public NodeDetectorState? NodeState { get; set; }
}

internal sealed class StateStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(CoreJson.Options) { WriteIndented = true };
    private readonly string directory;
    public StateStore(string? directory = null) => this.directory = directory ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexResetBar");
    public string FilePath => Path.Combine(directory, "state.json");
    public string? LoadWarning { get; private set; }
    public bool PreserveExistingBeforeSave { get; set; }

    public LocalState Load()
    {
        if (!File.Exists(FilePath)) return new();
        try
        {
            var state = JsonSerializer.Deserialize<LocalState>(File.ReadAllText(FilePath), JsonOptions)
                ?? throw new JsonException("本地配置为空。");
            if (state.Rules is null || state.Rules.Any(rule => rule is null))
                throw new JsonException("本地规则为空。");
            ReminderRule.Validate(state.Rules);
            return state;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or ArgumentException)
        {
            LoadWarning = "本地设置无法读取；原文件将在保存前备份。";
            PreserveExistingBeforeSave = true;
            return new();
        }
    }

    public void Save(LocalState state)
    {
        Directory.CreateDirectory(directory);
        if (PreserveExistingBeforeSave && File.Exists(FilePath))
        {
            File.Copy(FilePath, FilePath + ".recovery-" + DateTimeOffset.Now.ToString("yyyyMMddHHmmssfff") + ".bak");
            PreserveExistingBeforeSave = false;
        }
        string temporary = FilePath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(state, JsonOptions), Encoding.UTF8);
        File.Move(temporary, FilePath, overwrite: true);
    }
}

internal static class Dpapi
{
    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob { public int Length; public IntPtr Data; }
    private const uint UiForbidden = 1;
    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref DataBlob input, string? description, IntPtr entropy,
        IntPtr reserved, IntPtr prompt, uint flags, out DataBlob output);
    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref DataBlob input, IntPtr description, IntPtr entropy,
        IntPtr reserved, IntPtr prompt, uint flags, out DataBlob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);

    public static string Protect(string value) => Convert.ToBase64String(Transform(Encoding.UTF8.GetBytes(value), true));
    public static string Unprotect(string value)
    {
        byte[] plain = Transform(Convert.FromBase64String(value), false);
        try { return Encoding.UTF8.GetString(plain); }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }
    private static byte[] Transform(byte[] bytes, bool protect)
    {
        var input = new DataBlob { Length = bytes.Length, Data = Marshal.AllocHGlobal(bytes.Length) };
        DataBlob output = default;
        try
        {
            Marshal.Copy(bytes, 0, input.Data, bytes.Length);
            bool success = protect
                ? CryptProtectData(ref input, null, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, UiForbidden, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, UiForbidden, out output);
            if (!success) throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows 无法访问此用户的加密配置。");
            byte[] result = new byte[output.Length];
            Marshal.Copy(output.Data, result, 0, output.Length);
            return result;
        }
        finally
        {
            if (input.Data != IntPtr.Zero)
            {
                Marshal.Copy(new byte[bytes.Length], 0, input.Data, bytes.Length);
                Marshal.FreeHGlobal(input.Data);
            }
            if (output.Data != IntPtr.Zero)
            {
                Marshal.Copy(new byte[output.Length], 0, output.Data, output.Length);
                LocalFree(output.Data);
            }
            CryptographicOperations.ZeroMemory(bytes);
        }
    }
}

internal static class LoginStartup
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "CodexResetBar";
    public static bool Enabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return string.Equals(key?.GetValue(Name) as string, Command, StringComparison.OrdinalIgnoreCase);
        }
    }
    private static string Command => $"\"{Environment.ProcessPath}\" --background";
    public static void Set(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled) key.SetValue(Name, Command, RegistryValueKind.String);
        else key.DeleteValue(Name, throwOnMissingValue: false);
    }
}
