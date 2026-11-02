using CodexResetBar.Core;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Media;
using System.Text.Json;

namespace CodexResetBar;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (args.Contains("--self-test", StringComparer.OrdinalIgnoreCase)) return SelfTest.Run();
        if (args.Contains("--probe", StringComparer.OrdinalIgnoreCase)) return Probe(args);
        using var mutex = new Mutex(true, @"Local\CodexResetBar", out bool created);
        if (!created) { MessageBox.Show("Codex 额度提醒已在运行，请从系统托盘打开。", "Codex 额度提醒"); return 0; }
        using var controller = new AppController(args.Contains("--background", StringComparer.OrdinalIgnoreCase));
        Application.Run(controller);
        return 0;
    }
    private static int Probe(string[] args)
    {
        try
        {
            int pathIndex = Array.FindIndex(args, x => x.Equals("--codex-path", StringComparison.OrdinalIgnoreCase));
            string? path = pathIndex >= 0 && pathIndex + 1 < args.Length ? args[pathIndex + 1] : null;
            var snapshot = new CodexClient().FetchAsync(path).GetAwaiter().GetResult();
            // Deliberately exclude account identity and all raw protocol/log output.
            Console.WriteLine(JsonSerializer.Serialize(new { snapshot.PlanName, snapshot.OrdinaryUsageAllowed,
                Windows = snapshot.Windows.Select(w => new { w.Title, w.RemainingPercent, w.ResetsAt }) }));
            return 0;
        }
        catch (CodexReadException ex) { Console.Error.WriteLine(ex.Message); return 2; }
        catch { Console.Error.WriteLine("读取额度失败。"); return 2; }
    }
}

internal sealed class AppController : ApplicationContext
{
    private readonly StateStore store = new();
    private readonly LocalState state;
    private readonly MainForm panel;
    private readonly NotifyIcon tray;
    private readonly System.Windows.Forms.Timer refreshTimer = new() { Interval = 60_000 };
    private readonly System.Windows.Forms.Timer nodeTimer = new() { Interval = 15_000 };
    private readonly System.Windows.Forms.Timer alarm = new() { Interval = 5_000 };
    private readonly CancellationTokenSource lifetime = new();
    private readonly CodexClient codex = new();
    private readonly ResetDetector reset;
    private readonly NodeDetector nodes;
    private readonly TaskActivityMonitor tasks = new();
    private readonly BarkClient bark = new();
    private readonly SemaphoreSlim phoneQueue = new(1);
    private readonly ToolStripMenuItem stopMenu;
    private UsageSnapshot? snapshot;
    private DateTimeOffset? lastSuccess;
    private string? error;
    private string? storageWarning;
    private string lastPhoneStatus = "尚未发送手机通知";
    private bool refreshing, polling, pending, quitting;
    private AlertForm? popup;
    private (DateTimeOffset At, string Title, string Body)? recent;

    public AppController(bool background)
    {
        state = store.Load(); storageWarning = store.LoadWarning;
        try { ReminderRule.Validate(state.Rules); }
        catch (ArgumentException) { state.Rules = ReminderRule.Presets.ToList(); store.PreserveExistingBeforeSave = true; storageWarning = "本地规则无效，已载入默认规则；原文件将在保存前备份。"; }
        reset = new ResetDetector(state.ResetState); nodes = new NodeDetector(state.NodeState);
        bool login = false;
        try { login = LoginStartup.Enabled; } catch { storageWarning = "无法读取登录启动设置。"; }
        panel = new MainForm(state, login);
        panel.RefreshRequested += async () => await Refresh();
        panel.StopRequested += StopAlert; panel.ExitRequested += Quit;
        panel.ChooseCliRequested += ChooseCli; panel.OpenCodexRequested += OpenCodex;
        panel.BarkRequested += OpenBark; panel.RulesRequested += OpenRules;
        panel.AboutRequested += () => { using var about = new AboutForm(); about.ShowDialog(panel); };
        panel.TestRequested += () => DeliverLocal("【测试】Codex 提醒", "这是声音与弹窗测试，当前额度未发生变化。", true, true);
        panel.SettingsChanged += () =>
        {
            try { SaveSettings(); }
            catch { MessageBox.Show(panel, "设置暂时无法保存，请检查本地目录。", "保存失败"); }
        };
        panel.StartupChanged += enabled =>
        {
            try { LoginStartup.Set(enabled); }
            catch { panel.ResetStartupCheck(); MessageBox.Show(panel, "无法修改当前用户的登录启动设置。", "设置未保存"); }
        };
        var menu = new ContextMenuStrip();
        menu.Items.Add("打开额度概览", null, (_, _) => panel.ShowPanel());
        menu.Items.Add("立即刷新", null, async (_, _) => await Refresh());
        stopMenu = new ToolStripMenuItem("确认并停止提醒", null, (_, _) => StopAlert()) { Enabled = false };
        menu.Items.Add(stopMenu); menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出监测", null, (_, _) => Quit());
        tray = new NotifyIcon { Text = "Codex 额度提醒 · 等待额度", Icon = AppIcon.Create(), ContextMenuStrip = menu, Visible = true };
        tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) panel.ShowPanel(); };
        alarm.Tick += (_, _) => SystemSounds.Exclamation.Play();
        refreshTimer.Tick += async (_, _) => await Refresh();
        nodeTimer.Tick += async (_, _) => await PollNodes();
        refreshTimer.Start(); nodeTimer.Start();
        UpdatePanel();
        if (!background) panel.ShowPanel();
        // BeginInvoke keeps all UI and detector state on the Windows message loop.
        panel.CreateControl();
        _ = panel.Handle;
        panel.BeginInvoke(async () => { await PollNodes(); await Refresh(); });
    }
    private async Task Refresh()
    {
        if (refreshing || quitting) return;
        refreshing = true; UpdatePanel();
        try
        {
            var fresh = await codex.FetchAsync(state.CodexPath, lifetime.Token);
            if (quitting) return;
            snapshot = fresh; lastSuccess = DateTimeOffset.Now; error = null;
            var recoveries = reset.Ingest(fresh, lastSuccess.Value);
            var reminders = nodes.Ingest(fresh, state.Rules, lastSuccess.Value);
            SaveDetectorState();
            foreach (var recovery in recoveries)
                await Deliver(state.PhoneTitle, state.PhoneBody, true, true, true);
            foreach (var reminder in reminders) await Deliver(reminder.Title, reminder.Body, reminder.Sound, reminder.Popup, reminder.Phone);
        }
        catch (OperationCanceledException) when (quitting) { }
        catch (CodexReadException ex) { error = ex.Message; }
        catch { error = "读取额度失败，请检查 CLI 和本机登录状态后重试。"; }
        finally { refreshing = false; if (!quitting) UpdatePanel(); }
    }
    private async Task PollNodes()
    {
        if (polling || quitting) return;
        polling = true;
        try
        {
            var reminders = nodes.Ingest(null, state.Rules, DateTimeOffset.Now).ToList();
            foreach (var signal in await tasks.PollAsync(lifetime.Token))
                reminders.AddRange(ReminderEvaluator.ForTaskSignal(signal, state.Rules));
            if (quitting) return;
            SaveDetectorState();
            foreach (var reminder in reminders) await Deliver(reminder.Title, reminder.Body, reminder.Sound, reminder.Popup, reminder.Phone);
        }
        catch (OperationCanceledException) when (quitting) { }
        catch { storageWarning = "任务事件暂时无法检查；额度监测将继续。"; }
        finally { polling = false; if (!quitting) { panel.RefreshCountdowns(); UpdatePanel(); } }
    }
    private async Task Deliver(string title, string body, bool sound, bool showPopup, bool phone)
    {
        if (quitting) return;
        DeliverLocal(title, body, sound && state.Sound, showPopup && state.Popup);
        if (phone && state.PhoneEnabled)
        {
            try { lastPhoneStatus = await SendPhone(AutomaticMessage(title, body), false); }
            catch (ArgumentException) { lastPhoneStatus = "手机文案超出长度限制，请缩短这条提醒的标题或正文。"; }
        }
        if (!quitting) panel.UpdatePhoneStatus(lastPhoneStatus);
    }
    internal static BarkMessage AutomaticMessage(string title, string body)
    {
        string safeTitle = new BarkMessage(title, "").Title;
        int budget = 2500 - Encoding.UTF8.GetByteCount(safeTitle), count = 0, used = 0;
        var text = new StringBuilder();
        var elements = StringInfo.GetTextElementEnumerator(body.Trim());
        while (count < 500 && elements.MoveNext())
        {
            string element = elements.GetTextElement(); int bytes = Encoding.UTF8.GetByteCount(element);
            if (used + bytes > budget) break;
            text.Append(element); used += bytes; count++;
        }
        return new BarkMessage(safeTitle, text.ToString());
    }
    private void DeliverLocal(string title, string body, bool sound, bool showPopup)
    {
        recent = (DateTimeOffset.Now, title, body);
        if (sound || showPopup) pending = true;
        if (sound) { SystemSounds.Exclamation.Play(); alarm.Start(); }
        if (showPopup)
        {
            var previous = popup; popup = null;
            previous?.CloseForReplacement(); previous?.Dispose();
            var alert = new AlertForm(title, body, StopAlert);
            popup = alert;
            alert.FormClosed += (_, _) => { if (ReferenceEquals(popup, alert)) popup = null; };
            alert.Show();
        }
        UpdatePanel();
    }
    private void StopAlert()
    {
        pending = false; alarm.Stop();
        var current = popup; popup = null;
        current?.CloseAfterAcknowledgement(); UpdatePanel();
    }
    private async Task<string> SendPhone(BarkMessage message, bool test)
    {
        if (state.ProtectedBarkKey is null) return "未发送：请先配置设备 Key。";
        try
        {
            await phoneQueue.WaitAsync(lifetime.Token);
            try
            {
                if (quitting) return "发送已取消";
                string key = Dpapi.Unprotect(state.ProtectedBarkKey);
                var result = await bark.SendAsync(key, message, test, lifetime.Token);
                return result switch
                {
                    BarkPushResult.Accepted => "Bark 服务已接受，请在手机确认收到。",
                    BarkPushResult.Rejected => "Bark 服务拒绝请求，请检查设备 Key。",
                    BarkPushResult.InvalidResponse => "Bark 响应无法确认，请稍后重试。",
                    BarkPushResult.TimedOut => "推送超时，未确认手机通知成功。",
                    _ => "网络连接失败，未确认手机通知成功。"
                };
            }
            finally { phoneQueue.Release(); }
        }
        catch (OperationCanceledException) { return "发送已取消"; }
        catch (ArgumentException) { return "推送内容或设备 Key 无效；测试前缀和后缀也计入文案长度限制。"; }
        catch { return "无法读取加密配置或发送推送，请重新保存 Key。"; }
    }
    private void SaveDetectorState()
    {
        state.ResetState = reset.State; state.NodeState = nodes.State;
        try { store.Save(state); storageWarning = null; }
        catch { storageWarning = "无法保存本地状态，请检查用户目录的写入权限。"; }
    }
    private void SaveSettings()
    {
        if (!state.Sound) alarm.Stop();
        store.Save(state);
        UpdatePanel();
    }
    private void OpenBark()
    {
        using var form = new BarkForm(state, SaveSettings, async () =>
        {
            lastPhoneStatus = await SendPhone(new BarkMessage(state.PhoneTitle, state.PhoneBody), true);
            if (!quitting) panel.UpdatePhoneStatus(lastPhoneStatus);
            return lastPhoneStatus;
        }, lastPhoneStatus);
        form.ShowDialog(panel);
    }
    private void OpenRules()
    {
        using var form = new RulesForm(state.Rules, rules =>
        {
            state.Rules = rules;
            nodes.Ingest(null, state.Rules, DateTimeOffset.Now);
            state.NodeState = nodes.State; SaveSettings();
        }, TestRule);
        form.ShowDialog(panel);
    }
    private Task<string> TestRule(ReminderRule rule) => TestRuleChannels(rule, state, DeliverLocal, async (message, test) =>
    {
        lastPhoneStatus = await SendPhone(message, test);
        if (!quitting) panel.UpdatePhoneStatus(lastPhoneStatus);
        return lastPhoneStatus;
    });
    internal static async Task<string> TestRuleChannels(ReminderRule rule, LocalState settings,
        Action<string, string, bool, bool> local, Func<BarkMessage, bool, Task<string>> phone)
    {
        bool sound = rule.Sound && settings.Sound, showPopup = rule.Popup && settings.Popup;
        local("【测试】" + rule.Title, rule.Body + "\n\n（测试通知，当前额度及任务状态未发生变化。）", sound, showPopup);
        string phoneStatus = !rule.Phone ? "未选中" : !settings.PhoneEnabled ? "手机通知总开关关闭" : "";
        if (rule.Phone && settings.PhoneEnabled)
        {
            try { phoneStatus = await phone(new BarkMessage(rule.Title, rule.Body), true); }
            catch (ArgumentException) { phoneStatus = "测试文案过长，请缩短标题或正文后重试。"; }
        }
        return $"声音：{(sound ? "已触发" : rule.Sound ? "主开关关闭" : "未选中")}；弹窗：{(showPopup ? "已显示" : rule.Popup ? "主开关关闭" : "未选中")}\n手机：{phoneStatus}";
    }
    private void ChooseCli()
    {
        using var picker = new OpenFileDialog { Title = "选择已安装的 Codex CLI", Filter = "Codex CLI (codex.exe;codex.cmd)|codex.exe;codex.cmd|应用程序 (*.exe;*.cmd)|*.exe;*.cmd",
            CheckFileExists = true, Multiselect = false };
        if (picker.ShowDialog(panel) != DialogResult.OK) return;
        try { state.CodexPath = CodexLocator.Resolve(picker.FileName); SaveSettings(); panel.UpdateCli(); _ = Refresh(); }
        catch (CodexReadException ex) { MessageBox.Show(panel, ex.Message, "CLI 路径无效"); }
        catch { MessageBox.Show(panel, "无法保存 CLI 设置，请检查本地目录。", "保存失败"); }
    }
    private void OpenCodex()
    {
        try { Process.Start(new ProcessStartInfo(CodexLocator.Resolve(state.CodexPath)) { UseShellExecute = true }); }
        catch (CodexReadException ex) { MessageBox.Show(panel, ex.Message, "无法打开 Codex"); }
        catch { MessageBox.Show(panel, "无法启动 Codex CLI，请在设置中选择已安装的程序。", "无法打开 Codex"); }
    }
    private void UpdatePanel()
    {
        if (quitting) return;
        panel.UpdateData(snapshot, error ?? storageWarning, lastSuccess, refreshing, pending, recent);
        stopMenu.Enabled = pending;
        string trayText = pending ? "Codex 有提醒待确认 · 点击打开" : snapshot?.Windows.FirstOrDefault() is { } window
            ? $"Codex {window.Title} 剩余 {Math.Floor(window.RemainingPercent):0}%" : "Codex 额度提醒 · 等待额度";
        tray.Text = trayText[..Math.Min(63, trayText.Length)];
    }
    private void Quit()
    {
        if (quitting) return;
        quitting = true; lifetime.Cancel(); refreshTimer.Stop(); nodeTimer.Stop(); alarm.Stop();
        tray.Visible = false;
        var current = popup; popup = null; current?.CloseForReplacement(); current?.Dispose();
        panel.AllowExit = true; panel.Close(); ExitThread();
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            quitting = true; lifetime.Cancel(); refreshTimer.Dispose(); nodeTimer.Dispose(); alarm.Dispose();
            tray.Visible = false; tray.Icon?.Dispose(); tray.ContextMenuStrip?.Dispose(); tray.Dispose();
            popup?.Dispose(); panel.Dispose(); bark.Dispose(); lifetime.Dispose();
        }
        base.Dispose(disposing);
    }
}
