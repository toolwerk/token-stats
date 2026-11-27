using TokenStats.Model;
using TokenStats.UI;

namespace TokenStats.Tests;

// Hinweissätze in Zustandsfarbe (Designer-Prüfung PR #5, Runde 12): mindestens 4,5 : 1 (WCAG AA) auf der
// getönten Hinweisfläche (Zustandsfarbe mit Deckkraft 0x26 über Fenster, Popup oder Steuerfläche).
// Gleiche Rechnung wie ContrastTests.swift.

public sealed class ContrastTests
{
    static double Luminance(int rgb)
    {
        double Channel(int shift)
        {
            var c = ((rgb >> shift) & 0xFF) / 255.0;
            return c <= 0.04045 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);
        }
        return 0.2126 * Channel(16) + 0.7152 * Channel(8) + 0.0722 * Channel(0);
    }

    static double Contrast(int a, int b)
    {
        double la = Luminance(a), lb = Luminance(b);
        return (Math.Max(la, lb) + 0.05) / (Math.Min(la, lb) + 0.05);
    }

    static int Tint(int color, int baseColor, double opacity = 0x26 / 255.0)
    {
        var result = 0;
        foreach (var shift in new[] { 16, 8, 0 })
        {
            double fg = (color >> shift) & 0xFF, bg = (baseColor >> shift) & 0xFF;
            result |= (int)Math.Round(opacity * fg + (1 - opacity) * bg) << shift;
        }
        return result;
    }

    [Theory]
    [InlineData(Severity.Warn)]
    [InlineData(Severity.Crit)]
    public void NoticeTextReachesAA(Severity severity)
    {
        foreach (var baseColor in new[] { 0xFFFFFF, 0xF9F9F9, 0xF3F3F3 })
        {
            var background = Tint(Palette.SeverityColor(severity, false), baseColor);
            Assert.True(Contrast(Palette.SeverityTextColor(severity, false), background) >= 4.5, $"hell auf {baseColor:X6}");
        }
        foreach (var baseColor in new[] { 0x202020, 0x2B2B2B, 0x353535 })
        {
            var background = Tint(Palette.SeverityColor(severity, true), baseColor);
            Assert.True(Contrast(Palette.SeverityTextColor(severity, true), background) >= 4.5, $"dunkel auf {baseColor:X6}");
        }
    }

    [Fact]
    public void OldLightRedFailed()
    {
        // Gegenprobe: das alte Rot als Text lag auf der hellen Hinweisfläche unter 4,5 : 1.
        Assert.True(Contrast(Palette.SeverityColor(Severity.Crit, false), Tint(Palette.SeverityColor(Severity.Crit, false), 0xF9F9F9)) < 4.5);
    }
}
