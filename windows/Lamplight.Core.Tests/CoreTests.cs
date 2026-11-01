using System.Globalization;
using Lamplight.Core;

namespace Lamplight.Core.Tests;

public class SessionLengthTests
{
    [Fact]
    public void DefaultIsUntilStopped()
    {
        Assert.True(new Settings().DefaultLength.IsUntilStopped);
        Assert.Null(SessionLength.UntilStopped.Duration);
        Assert.True(new SessionLength(-3).IsUntilStopped);
    }

    [Theory]
    [InlineData(0, "Until I turn it off")]
    [InlineData(1, "1 minute")]
    [InlineData(15, "15 minutes")]
    [InlineData(60, "1 hour")]
    [InlineData(480, "8 hours")]
    [InlineData(90, "1 h 30 min")]
    public void Titles(int minutes, string expected) => Assert.Equal(expected, new SessionLength(minutes).Title);

    [Fact]
    public void PresetsMatchTheMacApp() =>
        Assert.Equal(new[] { 15, 30, 60, 120, 240, 480 }, SessionLength.Presets.Select(p => p.Minutes));
}

public class SessionTests
{
    static readonly DateTime Start = new(2026, 10, 31, 18, 0, 0, DateTimeKind.Utc);

    [Fact]
    public void UntilStoppedNeverFinishes()
    {
        var s = new Session(Start, SessionLength.UntilStopped);
        Assert.Null(s.EndsAtUtc);
        Assert.False(s.IsFinished(Start.AddYears(1)));
    }

    [Fact]
    public void TimedSessionCountsDownAndFinishes()
    {
        var s = new Session(Start, new SessionLength(15));
        Assert.Equal(Start.AddMinutes(15), s.EndsAtUtc);
        Assert.Equal(TimeSpan.FromMinutes(10), s.Remaining(Start.AddMinutes(5)));
        Assert.False(s.IsFinished(Start.AddSeconds(899)));
        Assert.True(s.IsFinished(Start.AddMinutes(15)));
        Assert.Equal(TimeSpan.Zero, s.Remaining(Start.AddHours(2)));
    }
}

public class TimeTextTests
{
    [Fact]
    public void RemainingRoundsUp()
    {
        Assert.Equal("1 min left", TimeText.Remaining(TimeSpan.FromSeconds(1)));
        Assert.Equal("42 min left", TimeText.Remaining(TimeSpan.FromMinutes(42)));
        Assert.Equal("1 h 05 min left", TimeText.Remaining(TimeSpan.FromMinutes(65)));
    }

    [Fact]
    public void ClockUsesCulture() =>
        Assert.Equal("18:30", TimeText.Clock(new DateTime(2026, 1, 1, 18, 30, 0), new CultureInfo("en-GB")));
}

public class BatteryGuardTests
{
    [Fact]
    public void StopsOnlyOnBatteryAtOrBelowThreshold()
    {
        var g = new BatteryGuard(10);
        Assert.True(g.ShouldStop(true, 10));
        Assert.False(g.ShouldStop(true, 11));
        Assert.False(g.ShouldStop(false, 2));
        Assert.False(g.ShouldStop(true, null));
        Assert.False(new BatteryGuard(0).ShouldStop(true, 1));
    }
}

public class FlameCurveTests
{
    [Fact]
    public void LightFlaresPastFullThenSettles()
    {
        Assert.Equal(0, FlameCurve.Light(0), 6);
        Assert.Equal(1, FlameCurve.Light(1), 6);
        Assert.True(Enumerable.Range(1, 99).Select(i => FlameCurve.Light(i / 100.0)).Max() > 1.05);
    }

    [Fact]
    public void DimGoesFromFullToOut()
    {
        Assert.Equal(1, FlameCurve.Dim(0), 6);
        Assert.Equal(0, FlameCurve.Dim(1), 6);
    }
}

public class LidPowerPlanTests
{
    // Shape of real `powercfg /query SCHEME_CURRENT SUB_BUTTONS LIDACTION` output (English).
    const string English = """
        Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)
          Subgroup GUID: 4f971e89-eebd-4455-a8de-9e59040e7347  (Power buttons and lid)
            Power Setting GUID: 5ca83367-6e45-459f-a27b-476b1d01c936  (Lid close action)
              Possible Setting Index: 000
              Possible Setting Friendly Name: Do nothing
              Possible Setting Index: 001
              Possible Setting Friendly Name: Sleep
            Current AC Power Setting Index: 0x00000001
            Current DC Power Setting Index: 0x00000002
        """;

    // Same shape with translated labels (German).
    const string German = """
            Aktueller Wechselstrom-Energieeinstellungsindex: 0x00000000
            Aktueller Gleichstrom-Energieeinstellungsindex: 0x00000001
        """;

    [Fact]
    public void ParsesAcThenDc() => Assert.Equal((1, 2), LidPowerPlan.ParseCurrent(English));

    [Fact]
    public void ParsesTranslatedOutput() => Assert.Equal((0, 1), LidPowerPlan.ParseCurrent(German));

    [Fact]
    public void RejectsGarbage()
    {
        Assert.Null(LidPowerPlan.ParseCurrent("Access denied."));
        Assert.Null(LidPowerPlan.ParseCurrent("0x00000009 0x00000001"));
    }

    [Fact]
    public void SetArgsOnlyAcceptRealLidActions()
    {
        Assert.Equal(new[] { "/setacvalueindex", "SCHEME_CURRENT", "SUB_BUTTONS", "LIDACTION", "0" }, LidPowerPlan.SetAcArgs(0));
        Assert.Equal("3", LidPowerPlan.SetDcArgs(3)[^1]);
        Assert.Throws<ArgumentOutOfRangeException>(() => LidPowerPlan.SetAcArgs(4));
        Assert.Throws<ArgumentOutOfRangeException>(() => LidPowerPlan.SetDcArgs(-1));
    }

    [Fact]
    public void WatchdogWaitsThenRestores()
    {
        var script = LidPowerPlan.WatchdogScript(4242, 1, 2);
        Assert.StartsWith("Wait-Process -Id 4242", script);
        Assert.Contains("/setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 1;", script);
        Assert.Contains("/setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 2;", script);
        Assert.EndsWith("powercfg /setactive SCHEME_CURRENT", script);
        Assert.Throws<ArgumentOutOfRangeException>(() => LidPowerPlan.WatchdogScript(0, 1, 1));
        Assert.Throws<ArgumentOutOfRangeException>(() => LidPowerPlan.WatchdogScript(5, 7, 1));
    }
}

public class SettingsStoreTests
{
    [Fact]
    public void RoundTripsAndToleratesBadFiles()
    {
        var dir = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        var path = Path.Combine(dir, "settings.json");
        try
        {
            Assert.True(SettingsStore.Load(path).KeepAwakeWithLidClosed); // missing file -> defaults

            var s = new Settings { DefaultLengthMinutes = 60, LidEngaged = true, SavedLidAc = 1, SavedLidDc = 2, StopBelowBatteryPercent = 20 };
            SettingsStore.Save(s, path);
            var back = SettingsStore.Load(path);
            Assert.Equal(60, back.DefaultLengthMinutes);
            Assert.True(back.LidEngaged);
            Assert.Equal(1, back.SavedLidAc);
            Assert.Equal(2, back.SavedLidDc);
            Assert.Equal(20, back.StopBelowBatteryPercent);

            File.WriteAllText(path, "{ not json");
            Assert.Equal(0, SettingsStore.Load(path).DefaultLengthMinutes); // corrupt -> defaults
        }
        finally
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, true);
        }
    }
}
