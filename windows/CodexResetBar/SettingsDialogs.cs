using CodexResetBar.Core;
using System.Reflection;

namespace CodexResetBar;

internal sealed class BarkForm : Form
{
    private readonly LocalState state;
    private readonly Action save;
    private readonly Func<Task<string>> test;
    private readonly TextBox key = Theme.Input();
    private readonly TextBox title;
    private readonly TextBox body;
    private readonly CheckBox enabled;
    private readonly Label status;
    private readonly Button send;
    public BarkForm(LocalState state, Action save, Func<Task<string>> test, string? sendingStatus = null)
    {
        this.state = state; this.save = save; this.test = test;
        Theme.DialogLayout(this, 410, 560); Text = "iPhone / Bark 推送";
        var column = Theme.Column(366); column.Location = new Point(22, 14); Controls.Add(column);
        enabled = Theme.Check("启用手机通知", state.PhoneEnabled); Add(column, enabled, 30);
        Add(column, Theme.Label("Bark 设备 Key 或 https://api.day.app/… 地址", 9), 28);
        key.Name = "BarkKeyInput"; key.UseSystemPasswordChar = true; key.MaxLength = 512;
        key.PlaceholderText = state.ProtectedBarkKey is null ? "从 Bark 首页粘贴" : "已安全保存；输入可更换";
        Add(column, key, 29);
        Add(column, Theme.Label("Key 使用 Windows 当前用户加密保护。\n恢复提醒使用下面的文案；节点提醒使用各自规则文案。", 8, Theme.Muted), 46);
        Add(column, Theme.Label("恢复提醒标题（最多 100 字）"), 25);
        title = Theme.Input(state.PhoneTitle); title.Name = "BarkTitleInput"; Add(column, title, 29);
        Add(column, Theme.Label("恢复提醒正文（最多 500 字）"), 25);
        body = Theme.Input(state.PhoneBody, true); body.Name = "BarkBodyInput"; Add(column, body, 93);
        status = Theme.Label(sendingStatus ?? (state.ProtectedBarkKey is null ? "尚未配置设备 Key" : "已配置设备 Key"), 8, Theme.Muted);
        status.Name = "BarkStatusLabel"; Add(column, status, 43);
        var buttons = new FlowLayoutPanel { Width = 366, Height = 36, WrapContents = false, Margin = Padding.Empty };
        var saveButton = Theme.Button("保存", () => SaveSettings(), true); saveButton.Name = "SaveBarkButton"; saveButton.Width = 90;
        send = Theme.Button("发送测试", async () => await SendTest()); send.Name = "SendBarkTestButton"; send.Width = 116;
        var remove = Theme.Button("删除 Key", RemoveKey); remove.Name = "RemoveBarkKeyButton"; remove.Width = 126;
        buttons.Controls.AddRange([saveButton, send, remove]); Add(column, buttons, 36);
        Add(column, Theme.Label("发送成功表示 Bark 服务已接受，请在手机上确认收到。", 8, Theme.Muted), 39);
    }
    private bool SaveSettings()
    {
        try
        {
            var message = new BarkMessage(title.Text, body.Text);
            string? encrypted = state.ProtectedBarkKey;
            if (!string.IsNullOrWhiteSpace(key.Text)) encrypted = Dpapi.Protect(BarkClient.ParseDeviceKey(key.Text));
            if (enabled.Checked && encrypted is null) throw new ArgumentException("请先配置 Bark 设备 Key。");
            state.ProtectedBarkKey = encrypted; state.PhoneEnabled = enabled.Checked;
            state.PhoneTitle = message.Title; state.PhoneBody = message.Body; save();
            key.Clear(); key.PlaceholderText = "已安全保存；输入可更换";
            status.Text = "设置已保存，Key 不会以明文写入文件。"; status.ForeColor = Theme.Accent; return true;
        }
        catch (ArgumentException ex) { status.Text = ex.Message; }
        catch { status.Text = "保存失败，请检查本地目录或 Windows 加密服务。"; }
        status.ForeColor = Theme.Warning; return false;
    }
    private async Task SendTest()
    {
        if (!SaveSettings()) return;
        if (state.ProtectedBarkKey is null) { status.Text = "请先配置设备 Key。"; return; }
        send.Enabled = false; status.Text = "正在发送测试…";
        try { status.Text = await test(); }
        catch { status.Text = "未确认发送成功，请检查设置或网络后重试。"; }
        finally { if (!IsDisposed) send.Enabled = true; }
    }
    private void RemoveKey()
    {
        state.ProtectedBarkKey = null; state.PhoneEnabled = false; enabled.Checked = false; key.Clear();
        try { save(); status.Text = "设备 Key 已删除，手机通知已关闭。"; key.PlaceholderText = "从 Bark 首页粘贴"; }
        catch { status.Text = "未能保存删除操作，请检查本地目录后重试。"; }
    }
    private static void Add(FlowLayoutPanel column, Control control, int height)
    { control.Size = new Size(column.Width, height); control.Margin = new Padding(0, 0, 0, 6); column.Controls.Add(control); }
}

internal sealed class RulesForm : Form
{
    private readonly List<ReminderRule> rules;
    private readonly ListBox list = new() { BackColor = Theme.Surface, ForeColor = Theme.Text, BorderStyle = BorderStyle.FixedSingle };
    private readonly Label count = Theme.Label("", 8, Theme.Muted);
    private readonly ComboBox kind = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly Action<List<ReminderRule>> save;
    private readonly Button add;
    private readonly Button testSelected;
    private readonly Label testStatus = Theme.Label("", 8, Theme.Muted);
    private readonly Func<ReminderRule, Task<string>> test;
    private bool testing;
    public RulesForm(IReadOnlyList<ReminderRule> source, Action<List<ReminderRule>> save, Func<ReminderRule, Task<string>> test)
    {
        rules = source.Select(rule => rule with { }).ToList(); this.save = save; this.test = test;
        Theme.DialogLayout(this, 480, 600); Text = "关键节点提醒";
        var note = Theme.Label("额度规则依据成功读取的数据；任务规则只使用本机已验证的 Codex 事件。\n不会重放启动前的历史事件，预计重置不代表额度实际恢复。", 8, Theme.Muted);
        note.SetBounds(20, 12, 440, 50); Controls.Add(note);
        count.SetBounds(20, 63, 440, 25); Controls.Add(count);
        list.Name = "RulesList"; list.SetBounds(20, 92, 440, 244); list.DoubleClick += (_, _) => Edit(); Controls.Add(list);
        kind.Name = "NewRuleKind"; kind.SetBounds(20, 349, 278, 29);
        kind.Items.AddRange(Enum.GetValues<ReminderKind>().Select(x => new KindChoice(x)).Cast<object>().ToArray());
        kind.SelectedIndex = 0; Controls.Add(kind);
        add = Theme.Button("添加规则", Add); add.Name = "AddRuleButton"; add.SetBounds(311, 346, 149, 33); Controls.Add(add);
        var edit = Theme.Button("编辑所选", Edit); edit.Name = "EditRuleButton"; edit.SetBounds(20, 392, 135, 33);
        var delete = Theme.Button("删除所选", Delete); delete.Name = "DeleteRuleButton"; delete.SetBounds(171, 392, 135, 33);
        var done = Theme.Button("保存规则", Save, true); done.Name = "SaveRulesButton"; done.SetBounds(321, 392, 139, 33);
        Controls.AddRange([edit, delete, done]);
        testSelected = Theme.Button("测试所选规则", async () => await TestSelected());
        testSelected.Name = "TestSelectedRuleButton"; testSelected.SetBounds(20, 439, 440, 34); Controls.Add(testSelected);
        testStatus.Name = "RuleTestStatusLabel"; testStatus.SetBounds(20, 482, 440, 55); Controls.Add(testStatus);
        list.SelectedIndexChanged += (_, _) => testSelected.Enabled = !testing && list.SelectedIndex >= 0;
        var hint = Theme.Label("所有规则均可自定义标题、正文和声音 / 弹窗 / 手机通道。\n声音与弹窗还受主设置开关控制；最多保留 30 条。", 8, Theme.Muted);
        hint.SetBounds(20, 544, 440, 46); Controls.Add(hint); Reload();
    }
    private void Reload(int selected = 0)
    {
        list.Items.Clear(); list.Items.AddRange(rules.Select(x => $"{(x.Enabled ? "●" : "○")} {KindChoice.Title(x.Kind)} · {x.Title}").Cast<object>().ToArray());
        if (list.Items.Count > 0) list.SelectedIndex = Math.Clamp(selected, 0, list.Items.Count - 1);
        count.Text = $"已配置 {rules.Count} / 30 条规则"; add.Enabled = rules.Count < 30;
        testSelected.Enabled = !testing && list.SelectedIndex >= 0;
    }
    internal async Task TestSelected()
    {
        int index = list.SelectedIndex;
        if (testing || index < 0) return;
        testing = true; testSelected.Enabled = false;
        testStatus.Text = "正在测试所选通道…";
        try { string result = await test(rules[index] with { }); if (!IsDisposed) testStatus.Text = result; }
        catch { if (!IsDisposed) testStatus.Text = "测试未完成，请检查配置或网络后重试。"; }
        finally { testing = false; if (!IsDisposed) testSelected.Enabled = list.SelectedIndex >= 0; }
    }
    private void Add()
    {
        if (rules.Count >= 30 || kind.SelectedItem is not KindChoice choice) return;
        using var editor = new RuleEditorForm(ReminderRule.Create(choice.Kind));
        if (editor.ShowDialog(this) == DialogResult.OK) { rules.Add(editor.Rule); Reload(rules.Count - 1); }
    }
    private void Edit()
    {
        int index = list.SelectedIndex; if (index < 0) return;
        using var editor = new RuleEditorForm(rules[index]);
        if (editor.ShowDialog(this) == DialogResult.OK) { rules[index] = editor.Rule; Reload(index); }
    }
    private void Delete() { int index = list.SelectedIndex; if (index < 0) return; rules.RemoveAt(index); Reload(index); }
    private void Save()
    {
        try { ReminderRule.Validate(rules); save(rules); DialogResult = DialogResult.OK; Close(); }
        catch (ArgumentException ex) { MessageBox.Show(this, ex.Message, "请检查规则", MessageBoxButtons.OK, MessageBoxIcon.Information); }
        catch { MessageBox.Show(this, "无法保存规则，请检查本地目录后重试。", "保存失败"); }
    }
    private sealed record KindChoice(ReminderKind Kind)
    {
        public override string ToString() => Title(Kind);
        public static string Title(ReminderKind kind) => kind switch
        {
            ReminderKind.QuotaBelow => "剩余额度低于阈值", ReminderKind.ResetSoon => "预计重置前提醒",
            ReminderKind.Scheduled => "指定时间提醒", ReminderKind.TaskCompleted => "本轮任务完成",
            ReminderKind.TaskFailed => "执行步骤报错", ReminderKind.TaskNeedsInput => "任务提问 / 待确认", _ => "提醒"
        };
    }
}

internal sealed class RuleEditorForm : Form
{
    public ReminderRule Rule { get; private set; }
    public RuleEditorForm(ReminderRule rule)
    {
        Rule = rule with { }; Theme.DialogLayout(this, 440, 510); Text = "编辑提醒";
        var enabled = Theme.Check("启用这条规则", rule.Enabled); enabled.SetBounds(20, 12, 390, 28);
        var numeric = new NumericUpDown { Minimum = rule.Kind == ReminderKind.QuotaBelow ? 0 : 1,
            Maximum = rule.Kind == ReminderKind.QuotaBelow ? 100 : 10080, BackColor = Theme.Surface, ForeColor = Theme.Text };
        numeric.Value = Math.Clamp(rule.Kind == ReminderKind.QuotaBelow ? rule.Threshold : rule.MinutesBeforeReset, (int)numeric.Minimum, (int)numeric.Maximum);
        var label = Theme.Label(rule.Kind == ReminderKind.QuotaBelow ? "剩余额度阈值（%）" : "预计重置前（分钟）", 9);
        label.SetBounds(20, 49, 260, 28); numeric.SetBounds(295, 51, 125, 28); numeric.Name = "RuleThresholdInput";
        var date = new DateTimePicker { Format = DateTimePickerFormat.Custom, CustomFormat = "yyyy-MM-dd HH:mm:ss", Width = 260 };
        date.Name = "RuleScheduledTime"; date.SetBounds(20, 50, 400, 29);
        var local = rule.ScheduledAt.LocalDateTime;
        date.Value = local < date.MinDate || local > date.MaxDate ? DateTime.Now.AddHours(1) : local;
        bool threshold = rule.Kind is ReminderKind.QuotaBelow or ReminderKind.ResetSoon;
        label.Visible = numeric.Visible = threshold; date.Visible = rule.Kind == ReminderKind.Scheduled;
        var titleLabel = Theme.Label("标题（最多 100 字）"); titleLabel.SetBounds(20, 95, 400, 25);
        var title = Theme.Input(rule.Title); title.Name = "RuleTitleInput"; title.SetBounds(20, 126, 400, 29);
        var bodyLabel = Theme.Label("正文（最多 500 字）"); bodyLabel.SetBounds(20, 167, 400, 25);
        var body = Theme.Input(rule.Body, true); body.Name = "RuleBodyInput"; body.SetBounds(20, 198, 400, 139);
        var sound = Theme.Check("声音", rule.Sound); sound.SetBounds(20, 351, 105, 30);
        var popup = Theme.Check("弹窗", rule.Popup); popup.SetBounds(154, 351, 105, 30);
        var phone = Theme.Check("手机", rule.Phone); phone.SetBounds(288, 351, 105, 30);
        var note = Theme.Label("任务类规则仅由真实事件触发。定时规则需设置未来时间。", 8, Theme.Muted); note.SetBounds(20, 393, 400, 35);
        var save = Theme.Button("完成", () =>
        {
            try
            {
                var candidate = rule with { Enabled = enabled.Checked, Threshold = rule.Kind == ReminderKind.QuotaBelow ? (int)numeric.Value : rule.Threshold,
                    MinutesBeforeReset = rule.Kind == ReminderKind.ResetSoon ? (int)numeric.Value : rule.MinutesBeforeReset,
                    ScheduledAt = rule.Kind == ReminderKind.Scheduled ? new DateTimeOffset(date.Value) : rule.ScheduledAt,
                    Title = title.Text.Trim(), Body = body.Text.Trim(), Sound = sound.Checked, Popup = popup.Checked, Phone = phone.Checked };
                if (candidate.Kind == ReminderKind.Scheduled && candidate.Enabled && candidate.ScheduledAt <= DateTimeOffset.Now)
                    throw new ArgumentException("请设置未来的提醒时间。");
                ReminderRule.Validate([candidate]); Rule = candidate; DialogResult = DialogResult.OK; Close();
            }
            catch (ArgumentException ex) { MessageBox.Show(this, ex.Message, "请检查规则"); }
        }, true);
        save.Name = "SaveRuleButton"; save.SetBounds(285, 451, 135, 34);
        Controls.AddRange([enabled, label, numeric, date, titleLabel, title, bodyLabel, body, sound, popup, phone, note, save]);
        AcceptButton = save;
    }
}

internal sealed class AboutForm : Form
{
    private Image? qr;
    public AboutForm()
    {
        Theme.DialogLayout(this, 390, 548); Text = "关于 / 联系与商业授权";
        var title = Theme.Label("Codex 额度提醒  1.6.0", 13, bold: true); title.SetBounds(22, 14, 346, 34);
        var license = Theme.Label("仅限个人非商业使用。\n商业使用需取得开发者书面授权。", 9, Theme.Muted); license.SetBounds(22, 52, 346, 48);
        var account = Theme.Label("开发者微信：wubenxincom", 11, Theme.Accent, true); account.SetBounds(22, 111, 346, 30);
        var copy = Theme.Button("复制微信号", () => Clipboard.SetText("wubenxincom")); copy.Name = "CopyWechatButton"; copy.SetBounds(22, 153, 346, 34);
        var image = new PictureBox { Name = "WechatQrImage", SizeMode = PictureBoxSizeMode.Zoom, BackColor = Color.White };
        image.SetBounds(75, 203, 240, 240);
        using var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("CodexResetBar.wechat-qr.png");
        if (resource is not null) { using var source = Image.FromStream(resource); qr = new Bitmap(source); image.Image = qr; }
        var hint = Theme.Label("扫码联系开发者", 9, Theme.Muted); hint.SetBounds(22, 452, 346, 30); hint.TextAlign = ContentAlignment.MiddleCenter;
        var notices = Theme.Button("查看许可与第三方声明", () => { using var licenses = new LicenseForm(); licenses.ShowDialog(this); });
        notices.Name = "ViewLicensesButton"; notices.SetBounds(22, 494, 346, 34);
        Controls.AddRange([title, license, account, copy, image, hint, notices]);
    }
    protected override void Dispose(bool disposing) { if (disposing) qr?.Dispose(); base.Dispose(disposing); }
}

internal sealed class LicenseForm : Form
{
    internal static readonly (string Title, string Resource)[] Entries =
    [
        ("应用许可", "CodexResetBar.licenses.APP.txt"),
        (".NET Runtime 许可", "CodexResetBar.licenses.NET.txt"),
        ("Windows Forms 许可", "CodexResetBar.licenses.WindowsForms.txt"),
        (".NET 第三方声明", "CodexResetBar.licenses.ThirdParty.txt")
    ];
    internal static string ReadLicense(string resource)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource)
            ?? throw new InvalidOperationException("内嵌许可资源缺失。");
        using var reader = new StreamReader(stream); return reader.ReadToEnd();
    }
    public LicenseForm()
    {
        Theme.DialogLayout(this, 650, 560); Text = "许可与第三方声明";
        var picker = new ComboBox { Name = "LicensePicker", DropDownStyle = ComboBoxStyle.DropDownList };
        picker.SetBounds(18, 16, 614, 30); picker.Items.AddRange(Entries.Select(x => x.Title).Cast<object>().ToArray());
        var text = Theme.Input("", true); text.Name = "LicenseText"; text.ReadOnly = true;
        text.WordWrap = false; text.ScrollBars = ScrollBars.Both; text.SetBounds(18, 58, 614, 482);
        picker.SelectedIndexChanged += (_, _) => text.Text = ReadLicense(Entries[picker.SelectedIndex].Resource);
        Controls.AddRange([picker, text]); picker.SelectedIndex = 0;
    }
}

internal sealed class AlertForm : Form
{
    private readonly Action stop;
    private bool acknowledged, suppressAcknowledgement, closing;
    public AlertForm(string title, string body, Action stop)
    {
        this.stop = stop;
        Theme.DialogLayout(this, 400, 275); Text = "Codex 提醒"; TopMost = true;
        var heading = Theme.Label(title, 13, Theme.Accent, true); heading.SetBounds(20, 17, 360, 48);
        var message = Theme.Label(body, 10); message.SetBounds(20, 76, 360, 118);
        var confirm = Theme.Button("确认并停止提醒", Acknowledge, true); confirm.Name = "ConfirmAlertButton"; confirm.SetBounds(20, 216, 360, 36);
        Controls.AddRange([heading, message, confirm]); AcceptButton = confirm;
    }
    internal void Acknowledge()
    {
        if (acknowledged || suppressAcknowledgement) return;
        acknowledged = true; stop();
    }
    internal void CloseForReplacement()
    { suppressAcknowledgement = true; Close(); }
    internal void CloseAfterAcknowledgement()
    { if (!closing) { Close(); Dispose(); } }
    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        closing = true; Acknowledge();
        base.OnFormClosing(e);
    }
}
