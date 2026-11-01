using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Lamplight.Core;

/// <summary>How long a keep-awake session lasts. 0 minutes means until stopped (the default).</summary>
public readonly record struct SessionLength(int Minutes)
{
    public static readonly SessionLength UntilStopped = new(0);

    public static readonly SessionLength[] Presets =
        { new(15), new(30), new(60), new(120), new(240), new(480) };

    public bool IsUntilStopped => Minutes <= 0;

    public TimeSpan? Duration => IsUntilStopped ? null : TimeSpan.FromMinutes(Minutes);

    public string Title => Minutes switch
    {
        <= 0 => "Until I turn it off",
        1 => "1 minute",
        < 60 => $"{Minutes} minutes",
        60 => "1 hour",
        _ when Minutes % 60 == 0 => $"{Minutes / 60} hours",
        _ => $"{Minutes / 60} h {Minutes % 60} min",
    };
}

/// <summary>A running keep-awake session.</summary>
public sealed record Session(DateTime StartedAtUtc, SessionLength Length)
{
    public DateTime? EndsAtUtc => Length.Duration is { } d ? StartedAtUtc + d : null;

    /// <summary>Time left, or null when the session runs until stopped.</summary>
    public TimeSpan? Remaining(DateTime nowUtc)
    {
        if (EndsAtUtc is not { } end) return null;
        var left = end - nowUtc;
        return left < TimeSpan.Zero ? TimeSpan.Zero : left;
    }

    public bool IsFinished(DateTime nowUtc) => Remaining(nowUtc) is { } left && left <= TimeSpan.Zero;
}

public static class TimeText
{
    /// <summary>Rounds up, so "0 min left" never shows while a session is still running.</summary>
    static int WholeMinutes(TimeSpan t) => (int)Math.Ceiling(Math.Max(0, t.TotalSeconds) / 60.0);

    /// <summary>"42 min left", "1 h 05 min left".</summary>
    public static string Remaining(TimeSpan t)
    {
        var m = WholeMinutes(t);
        return m < 60 ? $"{m} min left" : $"{m / 60} h {m % 60:00} min left";
    }

    /// <summary>"6:30 PM" in the given culture.</summary>
    public static string Clock(DateTime local, CultureInfo? culture = null) =>
        local.ToString("t", culture ?? CultureInfo.CurrentCulture);
}

/// <summary>Ends a session before a laptop on battery runs flat. 0 means never.</summary>
public readonly record struct BatteryGuard(int Threshold)
{
    public static readonly int[] Choices = { 0, 5, 10, 20, 30 };
    public const int DefaultThreshold = 10;

    public int Clamped => Math.Clamp(Threshold, 0, 100);

    public bool ShouldStop(bool onBattery, int? percent) =>
        Clamped > 0 && onBattery && percent is { } p && p <= Clamped;
}

/// <summary>The flame animation, shared with the macOS app: it catches with a small flare, and dims quickly.</summary>
public static class FlameCurve
{
    public const double LightSeconds = 0.45;
    public const double DimSeconds = 0.30;

    public static double Light(double t)
    {
        const double c1 = 1.9, c3 = c1 + 1;
        var u = Math.Clamp(t, 0, 1) - 1;
        return 1 + c3 * u * u * u + c1 * u * u;
    }

    public static double Dim(double t)
    {
        t = Math.Clamp(t, 0, 1);
        return 1 - t * t;
    }
}

/// <summary>
/// Windows keeps running with the lid closed when the power plan's lid action is "Do nothing" (index 0).
/// Lamplight saves the current AC and DC values, sets both to 0 while it is on, and puts them back after.
/// </summary>
public static class LidPowerPlan
{
    public const int DoNothing = 0;

    public static readonly string[] QueryArgs = { "/query", "SCHEME_CURRENT", "SUB_BUTTONS", "LIDACTION" };
    public static readonly string[] ApplyArgs = { "/setactive", "SCHEME_CURRENT" };

    public static string[] SetAcArgs(int value) =>
        new[] { "/setacvalueindex", "SCHEME_CURRENT", "SUB_BUTTONS", "LIDACTION", Checked(value) };

    public static string[] SetDcArgs(int value) =>
        new[] { "/setdcvalueindex", "SCHEME_CURRENT", "SUB_BUTTONS", "LIDACTION", Checked(value) };

    /// <summary>Lid actions are 0 to 3 (nothing, sleep, hibernate, shut down). Anything else is refused.</summary>
    public static bool IsValidAction(int value) => value is >= 0 and <= 3;

    static string Checked(int value) =>
        IsValidAction(value) ? value.ToString(CultureInfo.InvariantCulture)
                             : throw new ArgumentOutOfRangeException(nameof(value));

    static readonly Regex Hex = new(@"0x([0-9a-fA-F]{8})", RegexOptions.Compiled);

    /// <summary>
    /// Reads the current AC and DC lid actions from `powercfg /query` output. The labels are translated on
    /// non-English Windows, so this takes the last two 0x-prefixed values, which are always AC then DC.
    /// </summary>
    public static (int Ac, int Dc)? ParseCurrent(string output)
    {
        var matches = Hex.Matches(output);
        if (matches.Count < 2) return null;
        var ac = int.Parse(matches[^2].Groups[1].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        var dc = int.Parse(matches[^1].Groups[1].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        return IsValidAction(ac) && IsValidAction(dc) ? (ac, dc) : null;
    }

    /// <summary>
    /// A hidden PowerShell process waits for Lamplight to exit, then restores the saved lid actions.
    /// It covers a crash or End Task while the lid action is changed. Only integers go into the script.
    /// </summary>
    public static string WatchdogScript(int processId, int ac, int dc)
    {
        if (processId <= 0) throw new ArgumentOutOfRangeException(nameof(processId));
        string a = Checked(ac), d = Checked(dc), id = processId.ToString(CultureInfo.InvariantCulture);
        return $"Wait-Process -Id {id} -ErrorAction SilentlyContinue; " +
               $"powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION {a}; " +
               $"powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION {d}; " +
               "powercfg /setactive SCHEME_CURRENT";
    }
}

/// <summary>User settings, stored as JSON in %APPDATA%\Lamplight\settings.json.</summary>
public sealed class Settings
{
    [JsonPropertyName("defaultLengthMinutes")] public int DefaultLengthMinutes { get; set; } = 0;
    [JsonPropertyName("keepAwakeWithLidClosed")] public bool KeepAwakeWithLidClosed { get; set; } = true;
    [JsonPropertyName("keepScreenOn")] public bool KeepScreenOn { get; set; } = true;
    [JsonPropertyName("stopBelowBatteryPercent")] public int StopBelowBatteryPercent { get; set; } = BatteryGuard.DefaultThreshold;

    /// <summary>Set after the first-run tip has been shown once.</summary>
    [JsonPropertyName("welcomed")] public bool Welcomed { get; set; }

    /// <summary>True while Lamplight has changed the lid action; the saved values are what to put back.</summary>
    [JsonPropertyName("lidEngaged")] public bool LidEngaged { get; set; }
    [JsonPropertyName("savedLidAc")] public int? SavedLidAc { get; set; }
    [JsonPropertyName("savedLidDc")] public int? SavedLidDc { get; set; }

    [JsonIgnore] public SessionLength DefaultLength => new(Math.Max(0, DefaultLengthMinutes));
}

public static class SettingsStore
{
    static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public static string DefaultPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Lamplight", "settings.json");

    /// <summary>Missing or unreadable files give the defaults instead of an error.</summary>
    public static Settings Load(string path)
    {
        try
        {
            if (File.Exists(path))
                return JsonSerializer.Deserialize<Settings>(File.ReadAllText(path), Options) ?? new Settings();
        }
        catch (JsonException) { }
        catch (IOException) { }
        return new Settings();
    }

    /// <summary>Writes to a temp file first and swaps it in, so a crash mid-write can't corrupt settings.</summary>
    public static void Save(Settings settings, string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(settings, Options));
        File.Move(temp, path, overwrite: true);
    }
}
