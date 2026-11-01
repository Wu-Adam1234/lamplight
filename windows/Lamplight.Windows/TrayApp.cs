using System.Diagnostics;
using System.Reflection;
using Lamplight.Core;
using Microsoft.Win32;

namespace Lamplight.Windows;

static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        // Used by CI to check the tray icon drawing on real Windows: Lamplight.exe --render-icons <folder>
        if (args.Length == 2 && args[0] == "--render-icons")
        {
            Directory.CreateDirectory(args[1]);
            foreach (var size in new[] { 16, 24, 32, 64 })
            foreach (var light in new[] { false, true })
            foreach (var (name, level) in new[] { ("off", 0.0), ("half", 0.5), ("flare", 1.12), ("on", 1.0) })
            {
                using var icon = LanternIcon.Create(level, size, light);
                using var bitmap = icon.ToBitmap();
                bitmap.Save(Path.Combine(args[1], $"lantern-{size}-{(light ? "light" : "dark")}-{name}.png"),
                            System.Drawing.Imaging.ImageFormat.Png);
            }
            return;
        }

        // One copy at a time: two would fight over the lid setting.
        using var mutex = new Mutex(initiallyOwned: true, @"Local\Lamplight.SingleInstance", out var firstCopy);
        if (!firstCopy) return;
        ApplicationConfiguration.Initialize();
        Application.Run(new TrayApp());
    }
}

/// <summary>The tray icon: left-click toggles, right-click opens the menu.</summary>
sealed class TrayApp : ApplicationContext
{
    const string RepoUrl = "https://github.com/Wu-Adam1234/lamplight";

    readonly string settingsPath = SettingsStore.DefaultPath;
    readonly Settings settings;
    readonly LidControl lid;
    readonly NotifyIcon tray = new();
    readonly ContextMenuStrip menu = new();
    readonly System.Windows.Forms.Timer tick = new() { Interval = 15_000 };
    readonly System.Windows.Forms.Timer endTimer = new();
    readonly System.Windows.Forms.Timer animation = new() { Interval = 16 };

    Session? session;
    bool ignoreBattery;
    string? lastStopNote;
    bool? shownLit;
    double iconLevel;
    DateTime animationStart;
    bool animatingToLit;
    bool exiting;

    BatteryGuard Guard => new(settings.StopBelowBatteryPercent);

    public TrayApp()
    {
        settings = SettingsStore.Load(settingsPath);
        lid = new LidControl(settings, Save);
        if (settings.LidEngaged) lid.Restore(); // Lamplight was closed unexpectedly while the lid setting was changed

        tray.ContextMenuStrip = menu;
        menu.Opening += (_, e) => { CheckSession(); BuildMenu(); e.Cancel = false; };
        tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) Toggle(); };
        tick.Tick += (_, _) => { CheckSession(); Refresh(); };
        endTimer.Tick += (_, _) => Stop($"Time ran out at {TimeText.Clock(DateTime.Now)}");
        animation.Tick += (_, _) => AnimationFrame();
        SystemEvents.UserPreferenceChanged += OnSystemChanged;
        SystemEvents.DisplaySettingsChanged += OnSystemChanged;
        SystemEvents.SessionEnding += OnSessionEnding;
        Application.ApplicationExit += (_, _) => Shutdown();

        Refresh();
        tray.Visible = true;

        if (!settings.Welcomed)
        {
            settings.Welcomed = true;
            Save();
            tray.ShowBalloonTip(8000, "Lamplight is in your system tray",
                "Click the lantern to keep your PC awake. Right-click it for timers and settings. " +
                "Can't see it? Click the ^ arrow next to the clock.", ToolTipIcon.None);
        }
    }

    // ---- Sessions ----

    void Toggle()
    {
        if (session is not null) Stop(null);
        else Start(settings.DefaultLength);
    }

    void Start(SessionLength length)
    {
        var ignore = false;
        if (Battery.Read() is { } battery && Guard.ShouldStop(battery.OnBattery, battery.Percent))
        {
            if (!ConfirmLowBattery(battery.Percent ?? 0)) return;
            ignore = true;
        }
        ignoreBattery = ignore;

        endTimer.Stop();
        session = new Session(DateTime.UtcNow, length);
        lastStopNote = null;
        KeepAwake.Hold(settings.KeepScreenOn);
        ApplyLidSetting();
        if (length.Duration is { } duration)
        {
            endTimer.Interval = (int)Math.Clamp(duration.TotalMilliseconds, 1, int.MaxValue);
            endTimer.Start();
        }
        tick.Start();
        Refresh();
    }

    void Stop(string? note)
    {
        endTimer.Stop();
        tick.Stop();
        var wasRunning = session is not null;
        session = null;
        KeepAwake.Release();
        ApplyLidSetting();
        if (wasRunning) lastStopNote = note;
        Refresh();
    }

    void CheckSession()
    {
        if (session is null) return;
        if (session.IsFinished(DateTime.UtcNow))
        {
            Stop($"Time ran out at {TimeText.Clock(DateTime.Now)}");
            return;
        }
        if (!ignoreBattery && Battery.Read() is { } battery && Guard.ShouldStop(battery.OnBattery, battery.Percent))
            Stop($"Turned off at {battery.Percent}% battery");
    }

    /// <summary>The lid setting is changed only while a session runs and the user wants it.</summary>
    void ApplyLidSetting()
    {
        var wanted = session is not null && settings.KeepAwakeWithLidClosed;
        if (wanted == settings.LidEngaged) return;
        if (wanted)
        {
            if (!lid.Engage())
            {
                settings.KeepAwakeWithLidClosed = false;
                Save();
                ShowError("Lid-closed mode didn't switch on",
                    $"{lid.LastError}\n\nYour PC will still sleep if you close the lid. Everything else works.");
            }
        }
        else if (!lid.Restore() && !exiting)
        {
            ShowError("Your lid setting wasn't put back",
                $"{lid.LastError}\n\nLamplight will try again next time it starts. To fix it now, open " +
                "Settings > System > Power & battery > Lid & power button controls.");
        }
    }

    // ---- Menu ----

    void BuildMenu()
    {
        foreach (var old in menu.Items.Cast<ToolStripItem>().ToList()) old.Dispose();
        menu.Items.Clear();

        foreach (var line in StatusLines())
            menu.Items.Add(new ToolStripMenuItem(line) { Enabled = false });
        menu.Items.Add(new ToolStripSeparator());

        if (session is not null)
        {
            menu.Items.Add(Item("Turn Off", () => Stop(null)));
            menu.Items.Add(LengthMenu("Restart For", session.Length, Start));
        }
        else
        {
            var title = settings.DefaultLength.IsUntilStopped ? "Turn On" : $"Turn On for {settings.DefaultLength.Title}";
            menu.Items.Add(Item(title, () => Start(settings.DefaultLength)));
            menu.Items.Add(LengthMenu("Turn On For", null, Start));
        }
        menu.Items.Add(new ToolStripSeparator());

        menu.Items.Add(Item("Keep Awake with Lid Closed", () =>
        {
            settings.KeepAwakeWithLidClosed = !settings.KeepAwakeWithLidClosed;
            Save();
            ApplyLidSetting();
            Refresh();
        }, settings.KeepAwakeWithLidClosed));
        menu.Items.Add(Item("Keep Screen On", () =>
        {
            settings.KeepScreenOn = !settings.KeepScreenOn;
            Save();
            if (session is not null) KeepAwake.Hold(settings.KeepScreenOn);
        }, settings.KeepScreenOn));
        if (Battery.Read() is not null) menu.Items.Add(BatteryMenu());
        menu.Items.Add(new ToolStripSeparator());

        menu.Items.Add(LengthMenu("Turn On Lasts", settings.DefaultLength, length =>
        {
            settings.DefaultLengthMinutes = length.Minutes;
            Save();
        }));
        menu.Items.Add(Item("Start with Windows", () =>
        {
            try { StartupItem.Set(!StartupItem.IsEnabled); }
            catch (Exception e) { ShowError("Couldn't change Start with Windows", e.Message); }
        }, StartupItem.IsEnabled));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(Item("About Lamplight", ShowAbout));
        menu.Items.Add(Item("Exit", Application.Exit));
    }

    IEnumerable<string> StatusLines()
    {
        if (session is null)
        {
            yield return "Lamplight is off";
            yield return lastStopNote ?? "Your PC sleeps as usual";
            yield break;
        }
        if (session.Remaining(DateTime.UtcNow) is { } left && session.EndsAtUtc is { } end)
        {
            yield return $"On, {TimeText.Remaining(left)}";
            yield return $"Turns off at {TimeText.Clock(end.ToLocalTime())}";
        }
        else
        {
            yield return "On until you turn it off";
        }
        yield return settings.LidEngaged ? "Stays awake with the lid closed" : "Closing the lid will put it to sleep";
    }

    static ToolStripMenuItem Item(string text, Action onClick, bool isChecked = false)
    {
        var item = new ToolStripMenuItem(text) { Checked = isChecked };
        item.Click += (_, _) => onClick();
        return item;
    }

    static ToolStripMenuItem LengthMenu(string title, SessionLength? current, Action<SessionLength> choose)
    {
        var parent = new ToolStripMenuItem(title);
        foreach (var length in new[] { SessionLength.UntilStopped }.Concat(SessionLength.Presets))
        {
            parent.DropDownItems.Add(Item(length.Title, () => choose(length), current == length));
            if (length.IsUntilStopped) parent.DropDownItems.Add(new ToolStripSeparator());
        }
        return parent;
    }

    ToolStripMenuItem BatteryMenu()
    {
        var parent = new ToolStripMenuItem("Turn Off on Low Battery");
        foreach (var threshold in BatteryGuard.Choices)
        {
            parent.DropDownItems.Add(Item(threshold == 0 ? "Never" : $"At {threshold}%", () =>
            {
                settings.StopBelowBatteryPercent = threshold;
                Save();
                ignoreBattery = false;
                CheckSession();
                Refresh();
            }, Guard.Clamped == threshold));
            if (threshold == 0) parent.DropDownItems.Add(new ToolStripSeparator());
        }
        return parent;
    }

    // ---- Icon ----

    void Refresh()
    {
        var lit = session is not null;
        if (shownLit is { } shown && shown != lit) Animate(lit);
        else if (!animation.Enabled) SetIcon(lit ? 1 : 0);
        shownLit = lit;

        var text = session switch
        {
            null => "Lamplight is off. Click to turn on, right-click for options.",
            { } s when s.Remaining(DateTime.UtcNow) is { } left => $"Lamplight is on, {TimeText.Remaining(left)}. Click to turn off.",
            _ => "Lamplight is on until you turn it off. Click to turn off.",
        };
        tray.Text = text.Length > 127 ? text[..127] : text;
    }

    void SetIcon(double level)
    {
        iconLevel = level;
        var size = Math.Max(16, SystemInformation.SmallIconSize.Width);
        var old = tray.Icon;
        tray.Icon = LanternIcon.Create(level, size, SystemPrefs.TaskbarIsLight);
        old?.Dispose();
    }

    /// <summary>The flame catches with a small flare when turning on, and shrinks to the wick when turning off.</summary>
    void Animate(bool toLit)
    {
        animation.Stop();
        if (!SystemPrefs.AnimationsEnabled)
        {
            SetIcon(toLit ? 1 : 0);
            return;
        }
        animatingToLit = toLit;
        animationStart = DateTime.UtcNow;
        animation.Start();
        AnimationFrame();
    }

    void AnimationFrame()
    {
        var seconds = animatingToLit ? FlameCurve.LightSeconds : FlameCurve.DimSeconds;
        var t = (DateTime.UtcNow - animationStart).TotalSeconds / seconds;
        if (t >= 1)
        {
            animation.Stop();
            SetIcon(animatingToLit ? 1 : 0);
            return;
        }
        SetIcon(animatingToLit ? FlameCurve.Light(t) : FlameCurve.Dim(t));
    }

    void OnSystemChanged(object? sender, EventArgs e) => SetIcon(iconLevel); // taskbar theme or DPI changed

    void OnSessionEnding(object? sender, SessionEndingEventArgs e)
    {
        exiting = true;
        Stop(null);
    }

    // ---- Dialogs ----

    bool ConfirmLowBattery(int percent)
    {
        var turnOn = new TaskDialogButton("Turn On Anyway");
        var page = new TaskDialogPage
        {
            Caption = "Lamplight",
            Heading = $"Battery is at {percent}%",
            Text = $"Lamplight normally turns off at {Guard.Clamped}%. Turn it on anyway? " +
                   "It will ignore the battery cutoff until you turn it off.",
            Buttons = { turnOn, TaskDialogButton.Cancel },
        };
        return TaskDialog.ShowDialog(page) == turnOn;
    }

    void ShowAbout()
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "1.0.0";
        var github = new TaskDialogButton("View on GitHub");
        var page = new TaskDialogPage
        {
            Caption = "About Lamplight",
            Heading = $"Lamplight {version}",
            Text = "Keeps your PC awake, lid open or closed.\nFree and open source under the MIT License.",
            Buttons = { github, TaskDialogButton.Close },
        };
        if (TaskDialog.ShowDialog(page) == github)
            Process.Start(new ProcessStartInfo(RepoUrl) { UseShellExecute = true });
    }

    static void ShowError(string heading, string text) =>
        TaskDialog.ShowDialog(new TaskDialogPage
        {
            Caption = "Lamplight",
            Heading = heading,
            Text = text,
            Icon = TaskDialogIcon.Warning,
            Buttons = { TaskDialogButton.OK },
        });

    // ---- Housekeeping ----

    void Save()
    {
        try { SettingsStore.Save(settings, settingsPath); }
        catch (Exception) { /* settings are a convenience; never crash over them */ }
    }

    void Shutdown()
    {
        exiting = true;
        Stop(null);
        SystemEvents.UserPreferenceChanged -= OnSystemChanged;
        SystemEvents.DisplaySettingsChanged -= OnSystemChanged;
        SystemEvents.SessionEnding -= OnSessionEnding;
        tray.Visible = false;
        tray.Icon?.Dispose();
        tray.Dispose();
        menu.Dispose();
    }
}
