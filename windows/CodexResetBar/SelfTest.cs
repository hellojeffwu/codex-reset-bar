using CodexResetBar.Core;
using System.Text.Json;
using System.Globalization;
using System.Text;

namespace CodexResetBar;

// This entry point uses isolated dummy state only. It does not create a tray icon,
// start timers, inspect ~/.codex, read saved keys, play audio, or access the network.
internal static class SelfTest
{
    public static int Run()
    {
        string directory = Path.Combine(Path.GetTempPath(), "CodexResetBar-selftest-" + Guid.NewGuid().ToString("N"));
        try
        {
            const string dummyKey = "selftest_dummy_key_never_send";
            var state = new LocalState { ProtectedBarkKey = Dpapi.Protect(dummyKey) };
            Require(state.ProtectedBarkKey != dummyKey, "DPAPI ciphertext");
            Require(Dpapi.Unprotect(state.ProtectedBarkKey) == dummyKey, "DPAPI roundtrip");
            var store = new StateStore(directory); store.Save(state);
            Require(!File.ReadAllText(store.FilePath).Contains(dummyKey, StringComparison.Ordinal), "No plaintext key on disk");
            var restored = store.Load();
            Require(Dpapi.Unprotect(restored.ProtectedBarkKey!) == dummyKey, "Persisted DPAPI roundtrip");
            VerifySettingsRecovery(directory);
            VerifyAlertAcknowledgement();
            VerifyTestChannels();
            var longBody = string.Concat(Enumerable.Repeat("👨‍👩‍👧‍👦", 500)) + " appended details";
            var bounded = AppController.AutomaticMessage("节点提醒", longBody);
            Require(new StringInfo(bounded.Body).LengthInTextElements <= 500 &&
                Encoding.UTF8.GetByteCount(bounded.Title) + Encoding.UTF8.GetByteCount(bounded.Body) <= 2500, "Automatic notification length budget");
            Require(bounded.Body.EndsWith("👨‍👩‍👧‍👦", StringComparison.Ordinal), "Automatic notification preserves graphemes");
            var fiveHundred = AppController.AutomaticMessage("节点提醒", new string('字', 500) + "附加详情");
            Require(fiveHundred.Body == new string('字', 500), "Valid 500-grapheme rule remains sendable");
            using var main = new MainForm(restored, false);
            using var bark = new BarkForm(restored, () => { }, () => Task.FromResult("self-test: no network"));
            int ruleTests = 0;
            RulesForm? testForm = null;
            using var rules = new RulesForm(restored.Rules, _ => { }, rule =>
            {
                ruleTests++; Require(rule.Id == restored.Rules[0].Id, "Selected rule test input");
                Require(!testForm!.Controls.Find("TestSelectedRuleButton", true).Single().Enabled, "Rule test disabled while sending");
                testForm.TestSelected().GetAwaiter().GetResult();
                return Task.FromResult("stub service accepted");
            });
            testForm = rules;
            using var about = new AboutForm();
            using var licenses = new LicenseForm();
            using var alert = new AlertForm("Self-test", "No sound, network or real notification was triggered.", () => { });
            CreateTree(main); CreateTree(bark); CreateTree(rules); CreateTree(about); CreateTree(alert); CreateTree(licenses);
            foreach (var name in new[] { "OverviewTab", "SettingsTab", "RefreshButton", "OpenCodexButton", "ChooseCliButton",
                         "BarkSettingsButton", "RulesSettingsButton", "AboutButton", "TestAlertButton", "ExitButton", "LoginStartupCheck" })
                Require(main.HasNamedControl(name), "Main control " + name);
            Require(Has(bark, "SaveBarkButton") && Has(bark, "SendBarkTestButton") && Has(bark, "BarkKeyInput"), "Bark controls");
            Require(Has(rules, "RulesList") && Has(rules, "SaveRulesButton") && Has(rules, "TestSelectedRuleButton"), "Rule controls");
            rules.TestSelected().GetAwaiter().GetResult();
            Require(ruleTests == 1, "Rule test prevents duplicate clicks");
            Require(rules.Controls.Find("RuleTestStatusLabel", true).Single().Text == "stub service accepted", "Rule test feedback");
            foreach (var entry in LicenseForm.Entries)
                Require(LicenseForm.ReadLicense(entry.Resource).Length > 100, "Embedded license " + entry.Title);
            Require(Has(about, "CopyWechatButton") && Has(about, "ViewLicensesButton"), "Contact and license controls");
            var qr = about.Controls.Find("WechatQrImage", true).OfType<PictureBox>().Single();
            Require(qr.Image is not null, "Embedded original QR image");
            Require(Has(alert, "ConfirmAlertButton"), "Explicit acknowledgement control");
            foreach (var kind in Enum.GetValues<ReminderKind>())
            {
                using var editor = new RuleEditorForm(ReminderRule.Create(kind));
                CreateTree(editor); Require(Has(editor, "SaveRuleButton") && Has(editor, "RuleBodyInput"), "Rule editor " + kind);
            }
            main.UpdateData(new UsageSnapshot(null, true, "test", [new("test", "测试额度", 23, 300, DateTimeOffset.Now.AddHours(1))]),
                null, DateTimeOffset.Now, false, false, null);
            string screenshots = Path.Combine(directory, "screenshots"); Directory.CreateDirectory(screenshots);
            Capture(main, Path.Combine(screenshots, "main-overview.png"));
            Require(main.ClientSize.Width == 360 && main.ClientSize.Height == 580, "Main panel dimensions");
            main.Show(); main.Controls.Find("SettingsTab", true).OfType<Button>().Single().PerformClick();
            Capture(main, Path.Combine(screenshots, "main-settings.png"));
            Capture(bark, Path.Combine(screenshots, "bark-settings.png"));
            Capture(rules, Path.Combine(screenshots, "rules.png"));
            Capture(about, Path.Combine(screenshots, "about.png"));
            string? artifacts = Environment.GetEnvironmentVariable("CODEX_SELF_TEST_ARTIFACT_DIR");
            if (!string.IsNullOrWhiteSpace(artifacts))
            {
                Directory.CreateDirectory(artifacts);
                foreach (string file in Directory.GetFiles(screenshots, "*.png"))
                    File.Copy(file, Path.Combine(artifacts, Path.GetFileName(file)), overwrite: true);
            }
            main.Close(); Require(!main.IsDisposed, "Close hides to tray");
            main.AllowExit = true; main.Close();
            Console.WriteLine("PASS: WinForms controls, quota render, close-to-tray, embedded contact/licenses, alert acknowledgement, stub rule testing, isolated DPAPI/config recovery.");
            return 0;
        }
        catch
        {
            // Never print exception payloads from crypto or configuration paths.
            Console.Error.WriteLine("FAIL: Windows UI self-test. No real credentials or notifications were used.");
            return 1;
        }
        finally { try { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); } catch { } }
    }
    private static void Capture(Form form, string path)
    {
        form.Show(); form.PerformLayout(); Application.DoEvents();
        using var bitmap = new Bitmap(form.Width, form.Height);
        form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size)); bitmap.Save(path);
        form.Hide();
    }
    private static void VerifySettingsRecovery(string root)
    {
        string tooMany = JsonSerializer.Serialize(new LocalState
            { Rules = Enumerable.Range(0, 31).Select(_ => ReminderRule.Create(ReminderKind.QuotaBelow)).ToList() }, CoreJson.Options);
        var invalid = new[] { "null", "{\"rules\":null}", "{\"rules\":[null]}", tooMany };
        for (int index = 0; index < invalid.Length; index++)
        {
            string directory = Path.Combine(root, "invalid-" + index); Directory.CreateDirectory(directory);
            var store = new StateStore(directory); File.WriteAllText(store.FilePath, invalid[index]);
            var recovered = store.Load();
            Require(store.PreserveExistingBeforeSave && store.LoadWarning is not null, "Reject invalid settings " + index);
            ReminderRule.Validate(recovered.Rules); store.Save(recovered);
            string backup = Directory.GetFiles(directory, "*.bak").Single();
            Require(File.ReadAllText(backup) == invalid[index], "Preserve original settings " + index);
        }
    }
    private static void VerifyAlertAcknowledgement()
    {
        int acknowledgements = 0;
        using (var closed = new AlertForm("Self-test", "Dummy callback only", () => acknowledgements++))
        { CreateTree(closed); closed.Close(); }
        Require(acknowledgements == 1, "Closing alert acknowledges");
        using (var confirmed = new AlertForm("Self-test", "Dummy callback only", () => acknowledgements++))
        { CreateTree(confirmed); confirmed.Acknowledge(); confirmed.Close(); }
        Require(acknowledgements == 2, "Confirm and close acknowledges once");
        using (var replaced = new AlertForm("Self-test", "Dummy callback only", () => acknowledgements++))
        { CreateTree(replaced); replaced.CloseForReplacement(); }
        Require(acknowledgements == 2, "Replacing old alert preserves current alarm");
    }
    private static void VerifyTestChannels()
    {
        var rule = ReminderRule.Create(ReminderKind.TaskCompleted);
        var settings = new LocalState { Sound = false, Popup = false, PhoneEnabled = false };
        bool sound = false, popup = false; int phone = 0;
        void Local(string title, string body, bool useSound, bool usePopup)
        {
            Require(title.StartsWith("【测试】", StringComparison.Ordinal) && body.Contains("测试通知", StringComparison.Ordinal), "Rule test marked as test");
            sound = useSound; popup = usePopup;
        }
        Task<string> Phone(BarkMessage message, bool test)
        { Require(test && message.Title == rule.Title, "Bark test flag and selected message"); phone++; return Task.FromResult("stub accepted"); }
        string disabled = AppController.TestRuleChannels(rule, settings, Local, Phone).GetAwaiter().GetResult();
        Require(!sound && !popup && phone == 0 && disabled.Contains("主开关关闭", StringComparison.Ordinal), "Rule test respects master switches");
        settings.Sound = settings.Popup = settings.PhoneEnabled = true;
        string sent = AppController.TestRuleChannels(rule, settings, Local, Phone).GetAwaiter().GetResult();
        Require(sound && popup && phone == 1 && sent.Contains("stub accepted", StringComparison.Ordinal), "Selected rule channels and feedback");
        AppController.TestRuleChannels(rule with { Sound = false, Popup = false, Phone = false }, settings, Local, Phone).GetAwaiter().GetResult();
        Require(!sound && !popup && phone == 1, "Unselected rule channels stay silent");
    }
    private static void CreateTree(Control control)
    { _ = control.Handle; foreach (Control child in control.Controls) CreateTree(child); }
    private static bool Has(Control control, string name) => control.Controls.Find(name, true).Length > 0;
    private static void Require(bool condition, string description)
    { if (!condition) throw new InvalidOperationException(description); }
}
