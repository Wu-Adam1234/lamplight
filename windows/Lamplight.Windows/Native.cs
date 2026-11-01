using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Lamplight.Core;
using Microsoft.Win32;

namespace Lamplight.Windows;

/// <summary>Stops idle sleep (and optionally screen sleep) while a session runs.</summary>
static class KeepAwake
{
    [Flags]
    enum ExecutionState : uint
    {
        Continuous = 0x80000000,
        SystemRequired = 0x00000001,
        DisplayRequired = 0x00000002,
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern ExecutionState SetThreadExecutionState(ExecutionState flags);

    /// <summary>Must be called on the UI thread, which lives as long as the app.</summary>
    public static bool Hold(bool keepScreenOn) =>
        SetThreadExecutionState(ExecutionState.Continuous | ExecutionState.SystemRequired |
                                (keepScreenOn ? ExecutionState.DisplayRequired : 0)) != 0;

    public static void Release() => SetThreadExecutionState(ExecutionState.Continuous);
}

/// <summary>
/// Changes the power plan's "When I close the lid" to "Do nothing" while a session runs,
/// and puts the user's own values back afterwards.
/// </summary>
sealed class LidControl
{
    readonly Settings settings;
    readonly Action save;
    Process? watchdog;

    public string? LastError { get; private set; }

    public LidControl(Settings settings, Action save)
    {
        this.settings = settings;
        this.save = save;
    }

    static string PowerCfg => Path.Combine(Environment.SystemDirectory, "powercfg.exe");
    static string PowerShell => Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");

    public bool Engage()
    {
        if (settings.LidEngaged) return true;
        var (code, output) = Run(PowerCfg, LidPowerPlan.QueryArgs);
        if (code != 0 || LidPowerPlan.ParseCurrent(output) is not { } current)
        {
            LastError = "Windows didn't report your current lid setting.";
            return false;
        }

        // Remember the user's values before changing anything, so a crash after this point can still undo it.
        settings.SavedLidAc = current.Ac;
        settings.SavedLidDc = current.Dc;
        settings.LidEngaged = true;
        save();

        if (!Set(LidPowerPlan.DoNothing, LidPowerPlan.DoNothing))
        {
            Set(current.Ac, current.Dc);
            settings.LidEngaged = false;
            save();
            LastError = "Windows didn't accept the change. Your power plan may be managed by your organization.";
            return false;
        }
        StartWatchdog(current.Ac, current.Dc);
        return true;
    }

    public bool Restore()
    {
        if (!settings.LidEngaged) return true;
        int ac = settings.SavedLidAc ?? 1, dc = settings.SavedLidDc ?? 1; // 1 = Sleep, the Windows default
        if (!LidPowerPlan.IsValidAction(ac)) ac = 1;
        if (!LidPowerPlan.IsValidAction(dc)) dc = 1;
        if (!Set(ac, dc))
        {
            LastError = "Windows didn't accept the change back.";
            return false;
        }
        settings.LidEngaged = false;
        settings.SavedLidAc = null;
        settings.SavedLidDc = null;
        save();
        StopWatchdog();
        return true;
    }

    static bool Set(int ac, int dc) =>
        Run(PowerCfg, LidPowerPlan.SetAcArgs(ac)).Code == 0 &&
        Run(PowerCfg, LidPowerPlan.SetDcArgs(dc)).Code == 0 &&
        Run(PowerCfg, LidPowerPlan.ApplyArgs).Code == 0;

    /// <summary>A hidden PowerShell process that restores the lid setting if Lamplight crashes or is ended.</summary>
    void StartWatchdog(int ac, int dc)
    {
        StopWatchdog();
        try
        {
            var info = new ProcessStartInfo(PowerShell)
            {
                CreateNoWindow = true,
                UseShellExecute = false,
                WindowStyle = ProcessWindowStyle.Hidden,
            };
            foreach (var arg in new[] { "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command",
                                        LidPowerPlan.WatchdogScript(Environment.ProcessId, ac, dc) })
                info.ArgumentList.Add(arg);
            watchdog = Process.Start(info);
        }
        catch (Exception)
        {
            watchdog = null; // the next launch still restores from settings
        }
    }

    void StopWatchdog()
    {
        try
        {
            if (watchdog is { HasExited: false }) watchdog.Kill();
        }
        catch (Exception) { }
        watchdog?.Dispose();
        watchdog = null;
    }

    static (int Code, string Output) Run(string exe, IEnumerable<string> args)
    {
        try
        {
            var info = new ProcessStartInfo(exe)
            {
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (var arg in args) info.ArgumentList.Add(arg);
            using var process = Process.Start(info)!;
            var output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
            if (!process.WaitForExit(15_000)) return (-1, output);
            return (process.ExitCode, output);
        }
        catch (Exception e)
        {
            return (-1, e.Message);
        }
    }
}

static class Battery
{
    /// <summary>Null on PCs without a battery.</summary>
    public static (bool OnBattery, int? Percent)? Read()
    {
        var status = SystemInformation.PowerStatus;
        if (status.BatteryChargeStatus.HasFlag(BatteryChargeStatus.NoSystemBattery) ||
            status.BatteryChargeStatus == BatteryChargeStatus.Unknown)
            return null;
        int? percent = status.BatteryLifePercent is >= 0 and <= 1
            ? (int)Math.Round(status.BatteryLifePercent * 100)
            : null;
        return (status.PowerLineStatus == PowerLineStatus.Offline, percent);
    }
}

/// <summary>Start with Windows, through the current user's Run key. No admin rights needed.</summary>
static class StartupItem
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Name = "Lamplight";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(Name) is string;
        }
    }

    public static void Set(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled && Environment.ProcessPath is { } path)
            key.SetValue(Name, $"\"{path}\"");
        else
            key.DeleteValue(Name, throwOnMissingValue: false);
    }
}

static class SystemPrefs
{
    const uint SpiGetClientAreaAnimation = 0x1042;

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool SystemParametersInfo(uint action, uint param, [MarshalAs(UnmanagedType.Bool)] out bool value, uint winIni);

    /// <summary>False when "Animation effects" is off in Settings > Accessibility > Visual effects.</summary>
    public static bool AnimationsEnabled => !SystemParametersInfo(SpiGetClientAreaAnimation, 0, out var on, 0) || on;

    public static bool TaskbarIsLight
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("SystemUsesLightTheme") is int value && value == 1;
        }
    }
}

/// <summary>The lantern, drawn in code on the same 18-unit grid as the macOS menu bar icon.</summary>
static class LanternIcon
{
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool DestroyIcon(IntPtr handle);

    static readonly Color Cream = Color.FromArgb(0xF4, 0xEE, 0xDF);
    static readonly Color Ink = Color.FromArgb(0x1A, 0x1F, 0x3A);
    static readonly Color Gold = Color.FromArgb(0xF2, 0xC1, 0x4E);
    static readonly Color Amber = Color.FromArgb(0xD9, 0x8A, 0x0B); // deeper flame for light taskbars

    /// <summary>level 0 is off (just the wick), 1 is fully lit; slightly above 1 is the flare.</summary>
    public static Icon Create(double level, int size, bool lightTaskbar)
    {
        using var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(Color.Transparent);
            // Flip to a y-up grid so the geometry matches the macOS drawing exactly.
            g.TranslateTransform(0, size);
            g.ScaleTransform(size / 18f, -size / 18f);
            Draw(g, (float)level, lightTaskbar ? Ink : Cream, lightTaskbar ? Amber : Gold);
        }
        var handle = bitmap.GetHicon();
        try
        {
            using var temporary = Icon.FromHandle(handle);
            return (Icon)temporary.Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    static void Draw(Graphics g, float level, Color body, Color flame)
    {
        using var pen = new Pen(body, 1.3f);
        using var fill = new SolidBrush(body);

        g.DrawEllipse(pen, 6.6f, 13.4f, 4.8f, 4.0f); // handle
        g.FillPolygon(fill, new[] { new PointF(4.8f, 12.4f), new PointF(13.2f, 12.4f), new PointF(11.4f, 14.6f), new PointF(6.6f, 14.6f) }); // cap

        var glass = new RectangleF(5.6f, 4.3f, 6.8f, 8.2f);
        var glow = Math.Clamp(level, 0f, 1f);
        if (glow > 0)
        {
            using var light = new SolidBrush(Color.FromArgb((int)(120 * glow), flame));
            using var glassFill = Rounded(glass, 1.6f);
            g.FillPath(light, glassFill);
        }
        using (var glassOutline = Rounded(RectangleF.Inflate(glass, -0.6f, -0.6f), 1.2f))
            g.DrawPath(pen, glassOutline);

        using (var basePath = Rounded(new RectangleF(4.4f, 2.2f, 9.2f, 2.1f), 0.9f))
            g.FillPath(fill, basePath);
        using (var wick = Rounded(new RectangleF(8.4f, 5.4f, 1.2f, 1.8f), 0.5f))
            g.FillPath(fill, wick);

        if (level > 0.03f)
        {
            using var brush = new SolidBrush(flame);
            using var path = Flame(9f, 5.6f, 5.6f + 5.4f * level, 1.9f * (0.55f + 0.45f * Math.Min(level, 1f)));
            g.FillPath(brush, path);
        }
    }

    static GraphicsPath Rounded(RectangleF r, float radius)
    {
        var d = radius * 2;
        var path = new GraphicsPath();
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    static GraphicsPath Flame(float x, float bottom, float top, float w)
    {
        var h = top - bottom;
        var path = new GraphicsPath();
        path.AddBezier(new PointF(x, top), new PointF(x + w * 0.25f, bottom + h * 0.78f), new PointF(x + w, bottom + h * 0.58f), new PointF(x + w, bottom + h * 0.3f));
        path.AddBezier(new PointF(x + w, bottom + h * 0.3f), new PointF(x + w, bottom + h * 0.1f), new PointF(x + w * 0.55f, bottom), new PointF(x, bottom));
        path.AddBezier(new PointF(x, bottom), new PointF(x - w * 0.55f, bottom), new PointF(x - w, bottom + h * 0.1f), new PointF(x - w, bottom + h * 0.3f));
        path.AddBezier(new PointF(x - w, bottom + h * 0.3f), new PointF(x - w, bottom + h * 0.58f), new PointF(x - w * 0.25f, bottom + h * 0.78f), new PointF(x, top));
        path.CloseFigure();
        return path;
    }
}
