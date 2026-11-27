#if DEBUG
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using TokenStats.Model;
using TokenStats.Providers;
using TokenStats.UI;
using TokenStats.Usage;

namespace TokenStats.App;

/// <summary>
/// <c>TOKENSTATS_SCREENSHOTS=&lt;Ordner&gt;</c>: rendert Popup und Tray-Symbol als PNG für die README,
/// dazu das App-Symbol <c>TokenStats.ico</c>, Szenen mit mehreren Konten (Popup und Einstellungen,
/// SPEC §6). Limits, Verbrauch und Konten sind Demo-Werte (<see cref="DemoAccounts"/>): keine Abfrage,
/// keine Kontoerkennung, kein Cache, keine Logs, keine echten Kontonamen, Adressen oder Ordner.
/// Einstellungen ohne Pfad: Bezeichnungen und Ausblenden wirken nur im Speicher.
/// </summary>
static class Screenshots
{
    public static void Run(string directory)
    {
        Directory.CreateDirectory(directory);
        var now = DateTimeOffset.Now;
        var settings = new AppSettings();
        // Keine echten Provider: Schon ihr Konstruktor liest die Kontodateien.
        var store = new UsageStore([], settings, cachePath: null);
        var consumption = new ConsumptionStore(settings, ledgerPath: null);
        store.ShowDemo(DemoSnapshots(now));
        consumption.ShowDemo(DemoUsage(now, settings.BillingDay, consumption.Prices), DemoRtk(now, settings.BillingDay));

        foreach (var (suffix, dark) in new[] { ("light", false), ("dark", true) })
        {
            var view = new PopupView(store, consumption, settings, () => { }) { Palette = new Palette(dark), Now = () => now };
            string File(string name) => Path.Combine(directory, $"{name}-{suffix}.png");

            view.Reset("claude");
            Save(Card(view.Build(), view.Palette), File("limits"));
            view.Reset("codex");
            Save(Card(view.Build(), view.Palette), File("limits-codex"));
            view.Reset("antigravity");
            Save(Card(view.Build(), view.Palette), File("limits-antigravity"));
            view.Reset("ollama");
            Save(Card(view.Build(), view.Palette), File("limits-ollama"));
            view.Reset("claude", PopupPage.Usage);
            Save(Card(view.Build(), view.Palette), File("usage"));
            Save(Tray(DemoSnapshots(now)["claude"].Windows, dark), File("tray"));
            AccountScenes(File, view.Palette, now, consumption);
        }
        SettingsScenes(directory, now, consumption);
        WriteIcon(Path.Combine(directory, "TokenStats.ico"));
    }

    // Mehrere Konten (SPEC §6)

    /// <summary>Einstellungen ohne Pfad und Store mit Demo-Konten eines Zustands; <paramref name="hidden"/> blendet ein Konto aus.</summary>
    static (AppSettings Settings, UsageStore Store) AccountScene(DemoAccounts.Scenario scenario, DateTimeOffset now, string? hidden = null)
    {
        var settings = new AppSettings();
        var store = new UsageStore([], settings, cachePath: null);
        var accounts = DemoAccounts.Accounts(scenario, now, DemoSnapshots(now))
            .Select(account => account.Id == hidden ? account with { Hidden = true } : account).ToList();
        DemoAccounts.Show(store, settings, accounts);
        return (settings, store);
    }

    /// <summary>
    /// Popup mit mehreren Konten: ohne Vorauswahl (das knappste Konto „Kunde A“ ist gewählt), fehlender
    /// Ordner sichtbar und ausgeblendet, Abruffehler HTTP 503 und „Nicht angemeldet“.
    /// </summary>
    static void AccountScenes(Func<string, string> file, Palette palette, DateTimeOffset now, ConsumptionStore consumption)
    {
        void Shot(string name, DemoAccounts.Scenario scenario, string? selected, string? hidden = null)
        {
            var (settings, store) = AccountScene(scenario, now, hidden);
            var view = new PopupView(store, consumption, settings, () => { }) { Palette = palette, Now = () => now };
            view.Reset(selected);
            Save(Card(view.Build(), palette), file(name));
        }

        Shot("limits-konten-mehrere", DemoAccounts.Scenario.Multi, selected: null);
        Shot("limits-konto-ordner-fehlt", DemoAccounts.Scenario.Invalid, DemoAccounts.KundeA);
        // Ausgeblendet steht „Kunde A“ nicht in der Kontoleiste; gewählt ist darum das Standardkonto.
        Shot("limits-konto-ordner-fehlt-ausgeblendet", DemoAccounts.Scenario.Invalid, "claude", hidden: DemoAccounts.KundeA);
        Shot("limits-konto-http-503", DemoAccounts.Scenario.Errors, DemoAccounts.KundeA);
        Shot("limits-konto-nicht-angemeldet", DemoAccounts.Scenario.Errors, DemoAccounts.Arbeit);
    }

    /// <summary>Breite der Client-Fläche des Einstellungsfensters (480 px außen, ohne Rahmen).</summary>
    const double SettingsWidth = 464;

    /// <summary>
    /// Einstellungen mit mehreren Konten, fehlendem Ordner sichtbar und ausgeblendet. Das Fenster wird
    /// nie angezeigt: Sein Inhalt wird offscreen in voller Höhe gezeichnet, hell und dunkel über das
    /// Fluent-Theme der App, das danach zurückgesetzt wird.
    /// </summary>
    static void SettingsScenes(string directory, DateTimeOffset now, ConsumptionStore consumption)
    {
        var app = Application.Current;
        var previous = app.ThemeMode;
        try
        {
            foreach (var (suffix, dark) in new[] { ("light", false), ("dark", true) })
            {
                app.ThemeMode = dark ? ThemeMode.Dark : ThemeMode.Light;
                void Shot(string name, DemoAccounts.Scenario scenario, string? hidden = null)
                {
                    var (settings, store) = AccountScene(scenario, now, hidden);
                    var window = new SettingsWindow(settings, store, consumption, dark);
                    Save(SettingsPage(window.DetachContent(), dark), Path.Combine(directory, $"{name}-{suffix}.png"));
                }

                Shot("einstellungen-konten-mehrere", DemoAccounts.Scenario.Multi);
                Shot("einstellungen-konto-ordner-fehlt", DemoAccounts.Scenario.Invalid);
                Shot("einstellungen-konto-ordner-fehlt-ausgeblendet", DemoAccounts.Scenario.Invalid, hidden: DemoAccounts.KundeA);
            }
        }
        finally
        {
            app.ThemeMode = previous;
        }
    }

    /// <summary>Inhalt des Einstellungsfensters auf der Fensterfläche, mit Schrift und Farben des Fenster-Stils.</summary>
    static FrameworkElement SettingsPage(FrameworkElement body, bool dark)
    {
        var app = Application.Current;
        // Mica lässt den Fenstergrund durchsichtig – dann die Grundfarbe des Themes, sonst eine feste.
        static Brush? Opaque(object? value) => value is SolidColorBrush { Color.A: 255 } brush ? brush : null;
        var host = new Border
        {
            Width = SettingsWidth,
            Child = body,
            Background = Opaque(WindowStyleValue(Control.BackgroundProperty))
                         ?? Opaque(app.TryFindResource("ApplicationBackgroundBrush"))
                         ?? Palette.Solid(dark ? 0x202020 : 0xF3F3F3),
        };
        TextElement.SetForeground(host, WindowStyleValue(Control.ForegroundProperty) as Brush
                                        ?? app.TryFindResource("TextFillColorPrimaryBrush") as Brush
                                        ?? (dark ? Brushes.White : Brushes.Black));
        TextElement.SetFontFamily(host, WindowStyleValue(Control.FontFamilyProperty) as FontFamily
                                        ?? app.TryFindResource("ContentControlThemeFontFamily") as FontFamily
                                        ?? SystemFonts.MessageFontFamily);
        TextElement.SetFontSize(host, WindowStyleValue(Control.FontSizeProperty) as double?
                                      ?? app.TryFindResource("ControlContentThemeFontSize") as double?
                                      ?? SystemFonts.MessageFontSize);
        host.Measure(new Size(SettingsWidth, double.PositiveInfinity));
        host.Arrange(new Rect(host.DesiredSize));
        host.UpdateLayout();
        return host;
    }

    /// <summary>Wert einer Eigenschaft aus dem impliziten Fenster-Stil des Themes, Ressourcen aufgelöst; <c>null</c>, wenn er sie nicht setzt.</summary>
    static object? WindowStyleValue(DependencyProperty property)
    {
        for (var style = Application.Current.TryFindResource(typeof(Window)) as Style; style is not null; style = style.BasedOn)
            foreach (var setter in style.Setters.OfType<Setter>())
                if (setter.Property == property)
                    return setter.Value is DynamicResourceExtension reference ? Application.Current.TryFindResource(reference.ResourceKey) : setter.Value;
        return null;
    }

    /// <summary>Popup-Rahmen nachgebildet: Karte mit runden Ecken, ohne Schatten.</summary>
    static FrameworkElement Card(FrameworkElement content, Palette palette)
    {
        var inner = new Border { Child = content, Clip = null };
        var card = new Border
        {
            CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1),
            Background = palette.Background, BorderBrush = palette.Separator, Child = inner,
        };
        card.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        card.Arrange(new Rect(card.DesiredSize));
        inner.Clip = new RectangleGeometry(new Rect(inner.RenderSize), 7, 7);
        card.UpdateLayout();
        return card;
    }

    /// <summary>Die drei Anzeige-Modi nebeneinander, in einem Stück Taskleiste.</summary>
    static FrameworkElement Tray(IReadOnlyList<LimitWindow> claude, bool dark)
    {
        var palette = new Palette(dark);
        var row = Ui.Row(22);
        foreach (var mode in MenuBarModes.All)
        {
            var icon = StatusIcon.Render(new StatusIcon.Input(
                mode, Severity.Warn, claude[1].Percent, claude.Take(2).Select(w => w.Percent).ToList(),
                Colored: true, Paused: false, TaskbarDark: dark), 32);
            var image = new Image { Source = icon, Width = 16, Height = 16 };
            RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.HighQuality);
            var tile = new Border
            {
                Width = 40, Height = 32, CornerRadius = new CornerRadius(4),
                Background = Palette.Solid(dark ? 0x1C1C1C : 0xEEEEEE), Child = image,
                HorizontalAlignment = HorizontalAlignment.Center,
            };
            var label = Ui.Text(mode.Label(), 11, palette.Secondary);
            label.HorizontalAlignment = HorizontalAlignment.Center;
            Ui.Add(row, Ui.Column(8, tile, label), 22);
        }
        row.Margin = new Thickness(20, 14, 20, 14);
        return Card(row, palette);
    }

    /// <summary>Zeichnet in 2× – scharf auch in der halb breiten README-Tabelle.</summary>
    static void Save(FrameworkElement element, string path)
    {
        const double scale = 2;
        var size = element.RenderSize;
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(size.Width * scale), (int)Math.Ceiling(size.Height * scale),
                                            96 * scale, 96 * scale, PixelFormats.Pbgra32);
        bitmap.Render(element);
        WritePng(bitmap, path);
        Console.WriteLine(Path.GetFileName(path));
    }

    static void WritePng(BitmapSource bitmap, string path)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(path);
        encoder.Save(stream);
    }

    /// <summary>App-Symbol: weißer Roboter auf blauem Grund, als ICO mit PNG-Bildern.</summary>
    static void WriteIcon(string path)
    {
        int[] sizes = [16, 24, 32, 48, 256];
        var images = sizes.Select(size =>
        {
            var visual = new DrawingVisual();
            using (var context = visual.RenderOpen())
            {
                var radius = size * 0.22;
                context.DrawRoundedRectangle(Palette.Solid(0x005FB8), null, new Rect(0, 0, size, size), radius, radius);
                RobotGlyph.Draw(context, new Rect(size * 0.12, size * 0.1, size * 0.76, size * 0.76), Brushes.White, minLine: 1.2);
            }
            var bitmap = new RenderTargetBitmap(size, size, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(visual);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var stream = new MemoryStream();
            encoder.Save(stream);
            return stream.ToArray();
        }).ToList();

        using var writer = new BinaryWriter(File.Create(path));
        writer.Write((short)0);
        writer.Write((short)1);
        writer.Write((short)sizes.Length);
        var offset = 6 + 16 * sizes.Length;
        for (var index = 0; index < sizes.Length; index++)
        {
            writer.Write((byte)(sizes[index] >= 256 ? 0 : sizes[index]));
            writer.Write((byte)(sizes[index] >= 256 ? 0 : sizes[index]));
            writer.Write((byte)0);
            writer.Write((byte)0);
            writer.Write((short)1);
            writer.Write((short)32);
            writer.Write(images[index].Length);
            writer.Write(offset);
            offset += images[index].Length;
        }
        foreach (var image in images) writer.Write(image);
    }

    // Demo-Werte

    /// <summary>Ein Stand, der alle Zustände zeigt: grün, gelb, Pace vorgegriffen, ungenutzt und im Takt.</summary>
    public static Dictionary<string, ProviderSnapshot> DemoSnapshots(DateTimeOffset now)
    {
        const double hour = 3600;
        const double week = 7 * 24 * hour;
        var weekReset = now.AddSeconds(2.6 * 24 * hour);
        return new()
        {
            ["claude"] = new ProviderSnapshot
            {
                Account = new AccountInfo("Demo", "Max 20×"),
                Windows =
                [
                    new() { Id = "session", Name = "Session", ScopeNote = "5 h", Percent = 0.42, ResetsAt = now.AddSeconds(2.2 * hour), WindowLength = 5 * hour },
                    new() { Id = "week", Name = "Woche", ScopeNote = "7 d, alle Modelle", Percent = 0.82, ResetsAt = weekReset, WindowLength = week },
                    new() { Id = "model-opus", Name = "Opus", ScopeNote = "Wochenlimit", Percent = 0.64, ResetsAt = weekReset, WindowLength = week },
                ],
                Extras = [new ExtraValue("extra", "Extra 12,40 $ / 50,00 $")],
                FetchedAt = now.AddSeconds(-60),
            },
            ["codex"] = new ProviderSnapshot
            {
                Account = new AccountInfo("Demo", "Pro"),
                Windows =
                [
                    new() { Id = "primary", Name = "Woche", ScopeNote = "7 d", Percent = 0.37, ResetsAt = now.AddSeconds(4.1 * 24 * hour), WindowLength = week },
                    new() { Id = "review", Name = "Code-Review", ScopeNote = "7 d", Percent = 0.08, ResetsAt = now.AddSeconds(4.1 * 24 * hour), WindowLength = week },
                ],
                Extras = [new ExtraValue("credits", "Credits unbegrenzt")],
                FetchedAt = now.AddSeconds(-60),
            },
            ["antigravity"] = new ProviderSnapshot
            {
                Account = new AccountInfo("Demo", "Google AI Plus"),
                Windows =
                [
                    new() { Id = "gemini-weekly", Name = "Gemini", ScopeNote = "Wochenlimit", Percent = 0.35, ResetsAt = now.AddSeconds(5.3 * 24 * hour), WindowLength = week },
                    new() { Id = "3p-weekly", Name = "Claude & GPT", ScopeNote = "Wochenlimit", Percent = 0.12, ResetsAt = now.AddSeconds(5.3 * 24 * hour), WindowLength = week },
                ],
                FetchedAt = now.AddSeconds(-60),
            },
            ["ollama"] = new ProviderSnapshot
            {
                Account = new AccountInfo("Demo", "Pro"),
                Windows =
                [
                    new() { Id = "session", Name = "Session", ScopeNote = "5 h", Percent = 0.18 },
                    new() { Id = "weekly", Name = "Woche", ScopeNote = "7 d", Percent = 0.41 },
                ],
                Extras = [new ExtraValue("requests-glm-5.3", "glm-5.3 · 312 Anfragen"), new ExtraValue("requests-kimi-k2.6", "kimi-k2.6 · 48 Anfragen")],
                FetchedAt = now.AddSeconds(-60),
            },
        };
    }

    /// <summary>30 Tage rtk-Ersparnis, etwa ein Viertel der Befehlsausgaben gefiltert.</summary>
    public static Dictionary<UsagePeriod, RtkSummary> DemoRtk(DateTimeOffset now, int billingDay)
    {
        double[] pattern = [0.8, 1.1, 0.6, 1.3, 0.2, 0, 0.4, 1.0, 1.2, 0.7, 1.5, 0.9, 0.1, 0,
                            0.9, 0.5, 1.4, 1.1, 0.6, 0.3, 0.1, 1.2, 0.8, 1.0, 1.7, 0.9, 0, 0.5, 1.3, 0.7];
        var today = DateOnly.FromDateTime(now.LocalDateTime);
        var days = pattern.Select((factor, index) => new RtkDay(
            UsageSummary.Key(today.AddDays(index - (pattern.Length - 1))),
            (long)(1_300 * factor), (long)(1_250_000 * factor), (long)(300_000 * factor))).ToList();
        return RtkSavings.Summaries(days, today, billingDay);
    }

    /// <summary>30 Tage Verbrauch mit Wochenrhythmus; Cache-Anteil wie bei Claude Code üblich um 80 %.</summary>
    public static Dictionary<string, Dictionary<UsagePeriod, UsageSummary>> DemoUsage(DateTimeOffset now, int billingDay, PriceTable prices)
    {
        // Tagesfaktoren, heute zuletzt; die Nullen sind freie Tage.
        double[] pattern = [0.9, 1.2, 0.7, 1.4, 0.3, 0, 0.5, 1.1, 1.3, 0.8, 1.6, 0.9, 0.2, 0,
                            1.0, 0.6, 1.5, 1.2, 0.7, 0.4, 0.1, 1.3, 0.9, 1.1, 1.8, 1.0, 0, 0.6, 1.4, 0.8];
        var models = new Dictionary<string, (string Model, double Share, TokenCounts PerDay)[]>
        {
            ["claude"] =
            [
                ("claude-opus-5-5", 0.7, new TokenCounts(9_000, 310_000, 1_900_000, 600_000, 38_000_000)),
                ("claude-sonnet-5", 0.3, new TokenCounts(14_000, 240_000, 1_400_000, 0, 21_000_000)),
            ],
            ["codex"] = [("gpt-5.6-sol", 1, new TokenCounts(Input: 1_100_000, Output: 180_000, CacheRead: 9_500_000))],
        };
        var today = DateOnly.FromDateTime(now.LocalDateTime);
        static TokenCounts Scaled(TokenCounts counts, double factor)
        {
            long S(long value) => (long)(value * factor);
            return new TokenCounts(S(counts.Input), S(counts.Output), S(counts.CacheWrite5m), S(counts.CacheWrite1h), S(counts.CacheRead));
        }

        return models.ToDictionary(pair => pair.Key, pair =>
        {
            var rows = pattern.SelectMany((factor, index) =>
            {
                var day = UsageSummary.Key(today.AddDays(index - (pattern.Length - 1)));
                return pair.Value.Select(line => new UsageLedger.Row(day, line.Model, Scaled(line.PerDay, factor * line.Share * 2)));
            }).ToList();
            return UsagePeriods.All.ToDictionary(period => period, period =>
            {
                var (from, through) = period.Range(today, billingDay);
                string first = UsageSummary.Key(from), last = UsageSummary.Key(through);
                var inRange = rows.Where(row => string.CompareOrdinal(row.Day, first) >= 0 && string.CompareOrdinal(row.Day, last) <= 0);
                return UsageSummary.Build(inRange, from, through, prices);
            });
        });
    }
}
#endif
