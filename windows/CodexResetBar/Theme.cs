using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace CodexResetBar;

internal static class Theme
{
    public static readonly Color Background = Color.FromArgb(18, 26, 32);
    public static readonly Color Surface = Color.FromArgb(28, 42, 48);
    public static readonly Color Accent = Color.FromArgb(74, 219, 194);
    public static readonly Color Text = Color.FromArgb(235, 244, 244);
    public static readonly Color Muted = Color.FromArgb(152, 173, 180);
    public static readonly Color Warning = Color.FromArgb(255, 188, 108);
    public static void Form(Form form)
    {
        form.BackColor = Background;
        form.ForeColor = Text;
        form.Font = new Font("Segoe UI", 9F);
        form.AutoScaleMode = AutoScaleMode.Dpi;
        form.StartPosition = FormStartPosition.CenterScreen;
        form.Icon = AppIcon.Create();
    }
    public static Label Label(string text, float size = 9, Color? color = null, bool bold = false)
        => new() { Text = text, AutoSize = false, ForeColor = color ?? Text,
            Font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular),
            BackColor = Color.Transparent, TextAlign = ContentAlignment.MiddleLeft };
    public static Button Button(string text, Action action, bool primary = false)
    {
        var button = new Button { Text = text, Height = 34, FlatStyle = FlatStyle.Flat,
            BackColor = primary ? Accent : Surface, ForeColor = primary ? Background : Text,
            Cursor = Cursors.Hand, UseVisualStyleBackColor = false, TabStop = true };
        button.FlatAppearance.BorderColor = primary ? Accent : Color.FromArgb(55, 79, 84);
        button.Click += (_, _) => action();
        return button;
    }
    public static TextBox Input(string value = "", bool multi = false)
        => new() { Text = value, BackColor = Surface, ForeColor = Text,
            BorderStyle = BorderStyle.FixedSingle, Multiline = multi,
            Height = multi ? 100 : 28, ScrollBars = multi ? ScrollBars.Vertical : ScrollBars.None };
    public static CheckBox Check(string title, bool value) => new()
        { Text = title, Checked = value, AutoSize = true, ForeColor = Text, Margin = new Padding(0, 8, 0, 8) };
    public static FlowLayoutPanel Column(int width) => new() { FlowDirection = FlowDirection.TopDown,
        WrapContents = false, AutoSize = true, Width = width, Margin = Padding.Empty,
        Padding = Padding.Empty, BackColor = Color.Transparent };
    public static void DialogLayout(Form form, int width, int height)
    {
        Form(form); form.ClientSize = new Size(width, height); form.FormBorderStyle = FormBorderStyle.FixedDialog;
        form.MaximizeBox = false; form.MinimizeBox = false;
    }
}

internal sealed class GradientPanel : Panel
{
    public GradientPanel() { DoubleBuffered = true; BackColor = Theme.Background; }
    protected override void OnPaintBackground(PaintEventArgs e)
    {
        using var brush = new LinearGradientBrush(ClientRectangle, Color.FromArgb(20, 36, 41),
            Theme.Background, LinearGradientMode.ForwardDiagonal);
        e.Graphics.FillRectangle(brush, ClientRectangle);
    }
}

internal static class AppIcon
{
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr handle);
    public static Icon Create()
    {
        using var bitmap = new Bitmap(32, 32);
        using var g = Graphics.FromImage(bitmap);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Color.Transparent);
        using var background = new SolidBrush(Theme.Background);
        g.FillEllipse(background, 1, 1, 30, 30);
        using var pen = new Pen(Theme.Accent, 3) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        g.DrawArc(pen, 7, 7, 18, 18, 35, 290);
        using var fill = new SolidBrush(Theme.Accent);
        g.FillPolygon(fill, [new PointF(23, 5), new PointF(27, 12), new PointF(19, 11)]);
        IntPtr handle = bitmap.GetHicon();
        try { return (Icon)Icon.FromHandle(handle).Clone(); }
        finally { DestroyIcon(handle); }
    }
}
