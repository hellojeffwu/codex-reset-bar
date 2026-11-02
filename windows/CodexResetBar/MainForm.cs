using CodexResetBar.Core;
using System.Drawing.Drawing2D;

namespace CodexResetBar;

internal sealed class MainForm : Form
{
    private readonly LocalState state;
    private readonly Label status = Theme.Label("等待检查本机 Codex", 8, Theme.Muted);
    private readonly Label plan = Theme.Label("", 8, Theme.Accent, true);
    private readonly Label updated = Theme.Label("尚未成功检查", 8, Theme.Muted);
    private readonly Button refresh;
    private readonly Button overviewTab;
    private readonly Button settingsTab;
    private readonly Panel viewport = new() { Dock = DockStyle.Fill, AutoScroll = true, Padding = new Padding(20, 0, 20, 0) };
    private readonly FlowLayoutPanel overview = Theme.Column(302);
    private readonly FlowLayoutPanel settings = Theme.Column(302);
    private readonly Button cliButton;
    private readonly Label phoneStatus = Theme.Label("尚未发送手机通知", 8, Theme.Muted);
    private bool resettingStartup;
    private bool showSettings;
    private UsageSnapshot? snapshot;
    private string? error;
    private bool alertPending;
    private (DateTimeOffset At, string Title, string Body)? lastEvent;
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    internal bool AllowExit { get; set; }
    public event Action? RefreshRequested, StopRequested, ExitRequested, ChooseCliRequested,
        OpenCodexRequested, BarkRequested, RulesRequested, AboutRequested, TestRequested, SettingsChanged;
    public event Action<bool>? StartupChanged;

    public MainForm(LocalState state, bool loginEnabled)
    {
        this.state = state;
        Theme.Form(this); Text = "Codex 额度提醒"; ClientSize = new Size(360, 580);
        FormBorderStyle = FormBorderStyle.FixedSingle; MaximizeBox = false;
        var background = new GradientPanel { Dock = DockStyle.Fill };
        Controls.Add(background);
        var header = new Panel { Dock = DockStyle.Top, Height = 78 };
        var logo = Theme.Label("↻", 28, Theme.Accent, true); logo.SetBounds(20, 12, 42, 48);
        var title = Theme.Label("Codex 额度提醒", 12, bold: true); title.SetBounds(72, 15, 200, 25);
        status.SetBounds(73, 42, 260, 20); plan.SetBounds(273, 15, 67, 25);
        plan.TextAlign = ContentAlignment.MiddleRight;
        header.Controls.AddRange([logo, title, status, plan]);
        var tabs = new Panel { Dock = DockStyle.Top, Height = 48 };
        overviewTab = Theme.Button("额度概览", () => SelectTab(false), true);
        overviewTab.Name = "OverviewTab"; overviewTab.SetBounds(20, 0, 158, 32);
        settingsTab = Theme.Button("提醒设置", () => SelectTab(true));
        settingsTab.Name = "SettingsTab"; settingsTab.SetBounds(182, 0, 158, 32);
        tabs.Controls.AddRange([overviewTab, settingsTab]);
        var footer = new Panel { Dock = DockStyle.Bottom, Height = 92 };
        updated.SetBounds(20, 2, 230, 22);
        refresh = Theme.Button("刷新", () => RefreshRequested?.Invoke());
        refresh.Name = "RefreshButton"; refresh.SetBounds(269, 0, 71, 28);
        var open = Theme.Button("打开 Codex 终端  ↗", () => OpenCodexRequested?.Invoke(), true);
        open.Name = "OpenCodexButton"; open.SetBounds(20, 37, 320, 35);
        footer.Controls.AddRange([updated, refresh, open]);
        background.Controls.Add(viewport); background.Controls.Add(footer);
        background.Controls.Add(tabs); background.Controls.Add(header);
        cliButton = Theme.Button(CliCaption, () => ChooseCliRequested?.Invoke());
        BuildSettings(loginEnabled);
        SelectTab(false);
    }

    private string CliCaption => state.CodexPath is null ? "选择 Codex CLI（当前自动查找）" : "更换 CLI：" + Path.GetFileName(state.CodexPath);
    public void UpdateCli() => cliButton.Text = CliCaption;
    public void UpdatePhoneStatus(string text) => phoneStatus.Text = text;
    public void ResetStartupCheck()
    {
        resettingStartup = true;
        try
        {
            var check = settings.Controls.Find("LoginStartupCheck", true).OfType<CheckBox>().FirstOrDefault();
            if (check is not null) check.Checked = LoginStartup.Enabled;
        }
        catch { }
        finally { resettingStartup = false; }
    }
    public void UpdateData(UsageSnapshot? value, string? failure, DateTimeOffset? lastSuccess, bool refreshing,
        bool pending, (DateTimeOffset At, string Title, string Body)? recent)
    {
        snapshot = value; error = failure; alertPending = pending; lastEvent = recent;
        status.Text = failure is not null ? "连接需要处理" : refreshing ? "正在读取额度…" : value is null ? "等待检查本机 Codex" : "正在监测本机 Codex";
        status.ForeColor = failure is not null ? Theme.Warning : Theme.Muted;
        plan.Text = value?.PlanName.ToUpperInvariant() ?? "";
        updated.Text = refreshing ? "正在检查…" : lastSuccess is { } at ? $"更新于 {at.LocalDateTime:HH:mm:ss}" : "尚未成功检查";
        refresh.Enabled = !refreshing;
        RebuildOverview();
    }
    public void RefreshCountdowns() { foreach (Control item in overview.Controls) item.Invalidate(); }
    public void ShowPanel()
    {
        Show(); WindowState = FormWindowState.Normal; Activate();
        if (Top < 0 || Left < 0) CenterToScreen();
    }
    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!AllowExit && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }
        base.OnFormClosing(e);
    }
    private void SelectTab(bool settingsSelected)
    {
        showSettings = settingsSelected;
        overviewTab.BackColor = showSettings ? Theme.Surface : Theme.Accent;
        overviewTab.ForeColor = showSettings ? Theme.Text : Theme.Background;
        settingsTab.BackColor = showSettings ? Theme.Accent : Theme.Surface;
        settingsTab.ForeColor = showSettings ? Theme.Background : Theme.Text;
        viewport.Controls.Clear(); viewport.Controls.Add(showSettings ? settings : overview);
        if (!showSettings) RebuildOverview();
    }
    private void RebuildOverview()
    {
        overview.SuspendLayout();
        foreach (Control control in overview.Controls.Cast<Control>().ToArray()) control.Dispose();
        overview.Controls.Clear();
        if (alertPending)
        {
            var stop = Theme.Button("有提醒等待确认 · 停止提醒", () => StopRequested?.Invoke());
            stop.Name = "StopAlertButton"; stop.ForeColor = Theme.Warning; Add(overview, stop, 40);
        }
        if (snapshot is { Windows.Count: > 0 })
            foreach (var window in snapshot.Windows) Add(overview, new QuotaCard(window), 210);
        else
            Add(overview, Theme.Label("等待额度数据\n\n连接这台 Windows 上已登录的 Codex。\n请先安装并登录 Codex CLI。", 10, Theme.Muted), 130);
        if (error is not null)
            Add(overview, Theme.Label(error + (snapshot is null ? "" : "\n当前显示最近成功读取的数据。"), 9, Theme.Warning), 84);
        if (lastEvent is { } recent)
        {
            var history = Theme.Label($"最近提醒  {recent.At.LocalDateTime:MM-dd HH:mm}\n{recent.Title}\n{recent.Body}", 8, Theme.Muted);
            history.BackColor = Theme.Surface; history.Padding = new Padding(10); Add(overview, history, 102);
        }
        Add(overview, Theme.Label("按实际额度恢复提醒，预计时间仅供参考。", 8, Theme.Muted), 29);
        overview.ResumeLayout();
    }
    private void BuildSettings(bool loginEnabled)
    {
        Add(settings, Theme.Label("提醒方式", 8, Theme.Muted), 25);
        AddCheck("重复声音", "每 5 秒响一次，确认后停止", state.Sound, value => state.Sound = value);
        AddCheck("弹窗提醒", "在电脑上显示可确认的提醒窗口", state.Popup, value => state.Popup = value);
        var login = AddCheck("登录时启动", "登录 Windows 后自动在托盘监测", loginEnabled, value => { if (!resettingStartup) StartupChanged?.Invoke(value); }, false);
        login.Name = "LoginStartupCheck";
        Add(settings, Theme.Label("更多设置", 8, Theme.Muted), 28);
        Link("iPhone / Bark 推送  ›", "安全保存设备 Key，自定义恢复提醒文案", () => BarkRequested?.Invoke(), "BarkSettingsButton");
        Add(settings, phoneStatus, 43);
        Link("关键节点提醒  ›", "额度、重置时间、定时与真实任务事件", () => RulesRequested?.Invoke(), "RulesSettingsButton");
        cliButton.Name = "ChooseCliButton"; Add(settings, cliButton, 35);
        Add(settings, Theme.Label("选择已安装的 codex.exe 或 codex.cmd。\n应用不会安装 CLI，也不会运行模型任务。", 8, Theme.Muted), 44);
        var test = Theme.Button("测试声音与弹窗", () => TestRequested?.Invoke());
        test.Name = "TestAlertButton"; Add(settings, test, 34);
        Add(settings, Theme.Label("测试会立即响铃；手机推送在 Bark 设置中单独测试。", 8, Theme.Muted), 40);
        Link("关于 / 联系与商业授权  ›", "仅个人非商业使用，商用需书面授权", () => AboutRequested?.Invoke(), "AboutButton");
        var exit = Theme.Button("退出监测", () => ExitRequested?.Invoke());
        exit.Name = "ExitButton"; Add(settings, exit, 34);
    }
    private CheckBox AddCheck(string title, string detail, bool value, Action<bool> changed, bool save = true)
    {
        var panel = new Panel { BackColor = Theme.Surface };
        var check = Theme.Check(title, value); check.Location = new Point(11, 5); check.Width = 280;
        var text = Theme.Label(detail, 8, Theme.Muted); text.SetBounds(11, 29, 280, 24);
        check.CheckedChanged += (_, _) => { changed(check.Checked); if (save) SettingsChanged?.Invoke(); };
        panel.Controls.AddRange([check, text]); Add(settings, panel, 62); return check;
    }
    private void Link(string title, string detail, Action action, string name)
    {
        var button = Theme.Button(title, action); button.TextAlign = ContentAlignment.MiddleLeft;
        button.Name = name; Add(settings, button, 34);
        Add(settings, Theme.Label(detail, 8, Theme.Muted), 29);
    }
    private static void Add(FlowLayoutPanel column, Control control, int height)
    { control.Size = new Size(column.Width, height); control.Margin = new Padding(0, 0, 0, 9); column.Controls.Add(control); }
    internal bool HasNamedControl(string name) => Find(Controls, name) || Find(settings.Controls, name);
    private static bool Find(Control.ControlCollection controls, string name) => controls.Cast<Control>()
        .Any(c => c.Name == name || Find(c.Controls, name));
}

internal sealed class QuotaCard(QuotaDisplayWindow window) : Control
{
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
        var accent = window.RemainingPercent <= 10 ? Theme.Warning : Theme.Accent;
        var rect = new Rectangle(0, 0, Width - 1, Height - 1);
        using var gradient = new LinearGradientBrush(rect, Color.FromArgb(29, 62, 64), Theme.Surface, 45F);
        g.FillRectangle(gradient, rect);
        using var border = new Pen(Color.FromArgb(45, 94, 94)); g.DrawRectangle(border, rect);
        DrawText(g, window.Title, 10, Theme.Muted, 17, 12, Width - 34, 24);
        DrawText(g, Math.Floor(window.RemainingPercent).ToString("0"), 38, Theme.Text, 13, 39, 138, 65, true);
        DrawText(g, "%", 19, accent, 147, 65, 38, 34, true);
        DrawText(g, "剩余额度", 8, Theme.Muted, Width - 79, 76, 66, 24);
        using var track = new SolidBrush(Color.FromArgb(47, 66, 73)); g.FillRectangle(track, 18, 112, Width - 36, 5);
        using var fill = new SolidBrush(accent); g.FillRectangle(fill, 18, 112, (float)((Width - 36) * window.RemainingPercent / 100), 5);
        using var separator = new Pen(Color.FromArgb(48, 67, 72)); g.DrawLine(separator, 18, 136, Width - 18, 136);
        DrawText(g, "预计重置", 8, Theme.Muted, 18, 148, 78, 24);
        string time = window.ResetsAt is { } at ? at.LocalDateTime.ToString("MM-dd HH:mm") : "暂未提供";
        DrawText(g, time, 9, Theme.Text, 132, 147, Width - 150, 24, false, ContentAlignment.MiddleRight);
        string countdown = window.ResetsAt is { } reset ? Countdown(reset) : "";
        DrawText(g, countdown, 8, Theme.Muted, 17, 176, Width - 34, 24, false, ContentAlignment.MiddleRight);
        AccessibleName = $"{window.Title}，剩余额度 {window.RemainingPercent:0}%";
    }
    private static string Countdown(DateTimeOffset at)
    {
        int minutes = (int)Math.Ceiling((at - DateTimeOffset.Now).TotalMinutes);
        if (minutes <= 0) return "预计时间已到，继续监测实际恢复";
        if (minutes >= 1440) return $"约 {minutes / 1440} 天 {minutes % 1440 / 60} 小时后";
        return minutes >= 60 ? $"约 {minutes / 60} 小时 {minutes % 60} 分钟后" : $"约 {minutes} 分钟后";
    }
    private static void DrawText(Graphics g, string text, float size, Color color, int x, int y, int w, int h,
        bool bold = false, ContentAlignment alignment = ContentAlignment.MiddleLeft)
    {
        using var font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular);
        TextRenderer.DrawText(g, text, font, new Rectangle(x, y, w, h), color,
            TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis |
            (alignment == ContentAlignment.MiddleRight ? TextFormatFlags.Right : TextFormatFlags.Left));
    }
}
