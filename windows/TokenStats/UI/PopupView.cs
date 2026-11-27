using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using TokenStats.Model;
using TokenStats.Providers;
using TokenStats.Usage;

namespace TokenStats.UI;

public enum PopupPage { Limits, Usage }

/// <summary>
/// Inhalt des Popups, 372 px breit: Kopf mit Seitenwahl · Tabs je Client · Seite · Fußzeile (SPEC §3).
/// Wird bei jeder Änderung komplett neu aufgebaut – so bleibt der Code nah an den SwiftUI-Views.
/// </summary>
public sealed class PopupView
{
    public const double Width = 372;
    /// <summary>Seitenrand aller Blöcke im Popup.</summary>
    const double Inset = 16;

    readonly UsageStore store;
    readonly ConsumptionStore consumption;
    readonly AppSettings settings;
    readonly Action openSettings;

    public Palette Palette { get; set; } = new(SystemTheme.AppsDark);
    public Func<DateTimeOffset> Now { get; set; } = () => DateTimeOffset.Now;

    /// <summary>Gewähltes Konto (oder Anbieter-ID); <c>null</c> = knappstes Konto über alle.</summary>
    string? selectedId;
    /// <summary>Zuletzt gewähltes Konto je Anbieter – ein Klick auf den Anbieter-Tab kehrt dorthin zurück.</summary>
    readonly Dictionary<string, string> lastByKind = [];
    /// <summary>Beim Öffnen steht immer „Limits“ – die Auswahl wird absichtlich nicht gemerkt.</summary>
    PopupPage page;
    UsagePeriod period = UsagePeriod.Week;

    public event Action? NeedsRender;

    public PopupView(UsageStore store, ConsumptionStore consumption, AppSettings settings, Action openSettings)
    {
        this.store = store;
        this.consumption = consumption;
        this.settings = settings;
        this.openSettings = openSettings;
    }

    public void Reset(string? selected = null, PopupPage startPage = PopupPage.Limits)
    {
        selectedId = selected;
        lastByKind.Clear();
        page = startPage;
        period = UsagePeriod.Week;
    }

    void Update(Action change)
    {
        change();
        NeedsRender?.Invoke();
    }

    public FrameworkElement Build()
    {
        var p = Palette;
        var entries = store.SortedEntries;
        // Ein Tab je Anbieter auf beiden Seiten; die Konten wählt auf „Limits“ die Kontoleiste.
        var kinds = entries.Select(entry => entry.Provider).DistinctBy(provider => provider.Kind).ToList();
        // Beim Öffnen ist das knappste Konto aktiv, die Tab-Reihenfolge bleibt fest.
        var activeId = selectedId ?? store.Tightest?.ProviderId;
        var selected = entries.FirstOrDefault(entry => entry.Id == activeId)
                       ?? entries.FirstOrDefault(entry => entry.Kind == activeId)
                       ?? entries.FirstOrDefault();

        var root = new StackPanel { Width = Width };
        root.Children.Add(Header());
        if (selected is null)
        {
            root.Children.Add(EmptyState());
        }
        else
        {
            root.Children.Add(TabBar(kinds, selected.Kind));
            var accounts = entries.Where(entry => entry.Kind == selected.Kind).ToList();
            if (page == PopupPage.Limits && accounts.Count >= 2) root.Children.Add(AccountBar(accounts, selected.Id));
            root.Children.Add(Ui.Divider(p.Separator));
            root.Children.Add(ProviderPage(selected));
        }
        root.Children.Add(Ui.Divider(p.Separator));
        root.Children.Add(Footer(selected is null ? null : store.State(selected.Id).Snapshot?.Account));
        return root;
    }

    /// <summary>Anbieter-Tab: zuletzt gewähltes Konto dieses Anbieters, sonst sein knappstes.</summary>
    void SelectKind(string kind)
    {
        var accounts = store.AccountsOfKind(kind);
        if (lastByKind.TryGetValue(kind, out var last) && accounts.Any(account => account.Id == last))
            selectedId = last;
        else
            selectedId = store.TightestOf(kind)?.ProviderId ?? accounts.FirstOrDefault()?.Id ?? kind;
    }

    void SelectAccount(AccountEntry entry)
    {
        selectedId = entry.Id;
        lastByKind[entry.Kind] = entry.Id;
    }

    /// <summary>
    /// Konto ohne Stand, das sich nicht abfragen lässt oder nur Fehler liefert: grau mit „!“ in der
    /// Kontoleiste, auf der Seite ein Hinweis mit „Einstellungen öffnen“.
    /// </summary>
    bool IsFaulty(AccountEntry entry)
    {
        var state = store.State(entry.Id);
        return entry.Status switch
        {
            AccountStatus.MissingFolder => true,
            AccountStatus.NotSignedIn => state.Snapshot is null,
            _ => state.Snapshot is null && state.Error is not null,
        };
    }

    // Kopf

    UIElement Header()
    {
        var p = Palette;
        var title = Ui.Row(8, new RobotIcon { Foreground = p.Primary }, Ui.Text("Token Stats", 13.5, p.Primary, FontWeights.Bold));
        var header = Ui.Spread(title, PageSwitch());
        header.Margin = new Thickness(Inset, 14, Inset, 12);
        return header;
    }

    /// <summary>Schlanker Umschalter in der Kopfzeile – bewusst leiser als ein Segmented Control.</summary>
    UIElement PageSwitch()
    {
        var p = Palette;
        var row = Ui.Row(2);
        foreach (var (option, label) in new[] { (PopupPage.Limits, "Limits"), (PopupPage.Usage, "Verbrauch") })
        {
            var isOn = option == page;
            var chip = new Border
            {
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(8, 2, 8, 3),
                Background = isOn ? p.Control : Brushes.Transparent,
                Child = Ui.Text(label, 11, isOn ? p.Primary : p.Secondary, isOn ? FontWeights.SemiBold : FontWeights.Normal),
            };
            Ui.Add(row, Ui.Clickable(chip, () => Update(() => page = option)), 2);
        }
        return new Border { CornerRadius = new CornerRadius(12), Padding = new Thickness(2), Background = p.Fill, Child = row };
    }

    // Tabs

    UIElement TabBar(List<IUsageProvider> kinds, string selectedKind)
    {
        var p = Palette;
        var row = Ui.Row(2);
        row.Margin = new Thickness(Inset - 10, 0, Inset - 10, 0);
        var visibleCount = VisibleTabCount(kinds.Select(provider => provider.DisplayName).ToList());
        foreach (var provider in kinds.Take(visibleCount))
        {
            var kind = provider.Kind;
            var isActive = kind == selectedKind;
            // Der Punkt zeigt das knappste sichtbare Konto des Anbieters.
            var severity = store.TightestOf(kind)?.Window.Severity;
            var content = Ui.Row(5, Dot(severity), Ui.Text(provider.DisplayName, 12, isActive ? p.Primary : p.Secondary, FontWeights.SemiBold));
            var tab = new Border
            {
                Padding = new Thickness(10, 7, 10, 7),
                BorderThickness = new Thickness(0, 0, 0, 2),
                BorderBrush = isActive ? p.Accent : Brushes.Transparent,
                Child = content,
            };
            Ui.Add(row, Ui.Clickable(tab, () => Update(() => SelectKind(kind))), 2);
        }

        // „+n“ nur für Anbieter, nie für Konten.
        var overflow = kinds.Skip(visibleCount).ToList();
        if (overflow.Count > 0)
        {
            var menu = new ContextMenu();
            foreach (var provider in overflow)
            {
                var kind = provider.Kind;
                var item = new MenuItem { Header = provider.DisplayName };
                item.Click += (_, _) => Update(() => SelectKind(kind));
                menu.Items.Add(item);
            }
            var more = new Border { Padding = new Thickness(10, 7, 10, 9), Child = Ui.Text($"+{overflow.Count}", 11.5, p.Secondary) };
            more.ContextMenu = menu;
            Ui.Add(row, Ui.Clickable(more, () =>
            {
                menu.PlacementTarget = more;
                menu.Placement = PlacementMode.Bottom;
                menu.IsOpen = true;
            }), 2);
        }
        return row;
    }

    /// <summary>Zustandspunkt: Farbe des knappsten Limits, grau ohne Stand.</summary>
    System.Windows.Shapes.Ellipse Dot(Severity? severity) => new()
    {
        Width = 5, Height = 5, VerticalAlignment = VerticalAlignment.Center,
        Fill = severity is { } s ? Palette.SeverityBrush(s) : Palette.Secondary,
        Opacity = severity is null ? 0.4 : 1,
    };

    /// <summary>
    /// Kontoleiste unter den Anbieter-Tabs (nur „Limits“, ab zwei Konten): Chips mit Zustandspunkt und
    /// ungekürzter Bezeichnung, die Leiste bricht um.
    /// </summary>
    UIElement AccountBar(List<AccountEntry> accounts, string currentId)
    {
        var p = Palette;
        var bar = new WrapPanel { Margin = new Thickness(Inset, 8, Inset - 6, 4) };
        foreach (var entry in accounts)
        {
            var isSelected = entry.Id == currentId;
            var faulty = IsFaulty(entry);
            var severity = faulty ? null : store.State(entry.Id).Snapshot?.TightestWindow?.Severity;
            var name = store.Label(entry.Provider) ?? entry.Provider.DisplayName;
            var text = Ui.Wrapped(faulty ? $"{name} !" : name, 11.5, faulty ? p.Secondary : isSelected ? p.Primary : p.Secondary);
            // Gleiche Schrift für alle Chips, sonst springt die Breite beim Wählen.
            text.VerticalAlignment = VerticalAlignment.Center;
            text.Margin = new Thickness(6, 0, 0, 0);
            var dot = Dot(severity);
            DockPanel.SetDock(dot, Dock.Left);
            // DockPanel statt StackPanel: Der Name bekommt die Restbreite und darf umbrechen.
            var content = new DockPanel { LastChildFill = true };
            content.Children.Add(dot);
            content.Children.Add(text);
            var chip = new Border
            {
                CornerRadius = new CornerRadius(11),
                BorderThickness = new Thickness(1),
                BorderBrush = isSelected ? p.Accent : p.Separator,
                Background = isSelected ? p.Control : Brushes.Transparent,
                Padding = new Thickness(9, 3, 10, 4),
                Child = content,
            };
            var clickable = Ui.Clickable(chip, () => Update(() => SelectAccount(entry)), store.Title(entry.Provider));
            clickable.Margin = new Thickness(0, 0, 6, 6);
            bar.Children.Add(clickable);
        }
        return bar;
    }

    UIElement EmptyState()
    {
        var p = Palette;
        var hint = Ui.Wrapped("Melde dich in Claude Code oder Codex an. Weitere Ordner fügst du in den Einstellungen unter „Konten“ hinzu.",
                              11, p.Secondary);
        hint.TextAlignment = TextAlignment.Center;
        var title = Ui.Wrapped("Kein Konto gefunden", 12.5, p.Primary);
        title.FontWeight = FontWeights.SemiBold;
        title.TextAlignment = TextAlignment.Center;
        var column = Ui.Column(6, title, hint);
        column.Margin = new Thickness(24);
        return column;
    }

    // Fußzeile

    UIElement Footer(AccountInfo? account)
    {
        var p = Palette;
        UIElement left = new Border();
        if (account?.Name is { Length: > 0 } name)
        {
            var avatar = new Border
            {
                Width = 19, Height = 19, CornerRadius = new CornerRadius(9.5), Background = p.Accent,
                Child = new TextBlock
                {
                    Text = name[..1].ToUpperInvariant(), FontFamily = Ui.Font, FontSize = 10, FontWeight = FontWeights.Bold,
                    Foreground = p.IsDark ? Brushes.Black : Brushes.White,
                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                },
            };
            var label = Ui.Wrapped(name, 11.5, p.Primary);
            label.FontWeight = FontWeights.SemiBold;
            label.VerticalAlignment = VerticalAlignment.Center;
            label.Margin = new Thickness(7, 0, 0, 0);
            avatar.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(avatar, Dock.Left);
            // Ungekürzt: Der Name nimmt die Restbreite und bricht notfalls um.
            var dock = new DockPanel { LastChildFill = true };
            dock.Children.Add(avatar);
            dock.Children.Add(label);
            left = dock;
        }

        var right = Ui.Row(8);
        if (store.LastUpdate is { } last)
        {
            var ago = Ui.Text(Format.Ago(last, Now()), 10.5, p.Secondary);
            ago.VerticalAlignment = VerticalAlignment.Center;
            Ui.Add(right, ago, 8);
        }
        var refreshContent = store.Loading.Count == 0
            ? (UIElement)Ui.Icon("", 12, p.Secondary)
            : Ui.Text("…", 12, p.Secondary, FontWeights.Bold);
        Ui.Add(right, FooterButton(refreshContent, "Aktualisieren", () => store.Refresh(manual: true)), 8);
        Ui.Add(right, FooterButton(
            Ui.Row(5, Ui.Icon("", 12, p.Secondary), Ui.Text("Einstellungen", 11.5, p.Secondary, FontWeights.SemiBold)),
            "Einstellungen (Strg+,)", openSettings), 8);

        var footer = Ui.Spread(left, right);
        // Links und rechts derselbe Innenabstand wie im übrigen Popup (Avatar bzw. Einstellungen-Knopf am Rand).
        return new Border { Background = p.Footer, Padding = new Thickness(Inset, 10, Inset, 10), Child = footer };
    }

    UIElement FooterButton(UIElement content, string help, Action action)
    {
        var p = Palette;
        var border = new Border
        {
            MinWidth = 26, MinHeight = 26,
            Padding = new Thickness(7, 0, 7, 0),
            CornerRadius = new CornerRadius(6),
            Background = p.Control,
            BorderBrush = p.Separator,
            BorderThickness = new Thickness(1),
            Child = content,
        };
        if (content is FrameworkElement element)
        {
            element.HorizontalAlignment = HorizontalAlignment.Center;
            element.VerticalAlignment = VerticalAlignment.Center;
        }
        return Ui.Clickable(border, action, help);
    }

    /// <summary>Wie viele Anbieter-Tabs in die Breite passen – gemessen statt fest.</summary>
    static int VisibleTabCount(List<string> titles)
    {
        const double available = Width - 2 * (Inset - 10);
        const double overflowWidth = 40;
        static double Measure(string text, double size, FontWeight weight) =>
            new FormattedText(text, Format.Culture, FlowDirection.LeftToRight,
                new Typeface(Ui.Font, FontStyles.Normal, weight, FontStretches.Normal), size, Brushes.Black, 1.0).WidthIncludingTrailingWhitespace;
        var widths = titles.Select(title => Math.Ceiling(Measure(title, 12, FontWeights.SemiBold)) + 5 + 5 + 20 + 2).ToList();
        if (widths.Sum() <= available) return titles.Count;
        double used = 0;
        var count = 0;
        foreach (var width in widths)
        {
            if (used + width + overflowWidth > available) break;
            used += width;
            count++;
        }
        return Math.Max(count, 1);
    }

    // Seiten „Limits“ und „Verbrauch“

    UIElement ProviderPage(AccountEntry entry)
    {
        var p = Palette;
        var provider = entry.Provider;
        var state = store.State(provider.Id);
        var column = Ui.Column(16);
        column.Margin = new Thickness(Inset, 16, Inset, 18);

        // „Verbrauch“ gilt je Anbieter und zählt nur Konten, deren Logs gelesen werden.
        var polledAccounts = store.PolledAccountsOfKind(provider.Kind);
        var accountCount = polledAccounts.Count;
        // WrapPanel: „Claude · Kunde A“ darf zweizeilig werden, der Plan rutscht dann nach unten.
        var title = new WrapPanel();
        var titleText = Ui.Wrapped(page == PopupPage.Usage ? provider.DisplayName : store.Title(provider), 13, p.Primary);
        titleText.FontWeight = FontWeights.Bold;
        titleText.VerticalAlignment = VerticalAlignment.Center;
        title.Children.Add(titleText);
        var detail = page == PopupPage.Usage && accountCount > 1 ? $"{accountCount} Konten" : state.Snapshot?.Account?.Plan;
        if (detail is not null)
        {
            var detailText = Ui.Text(detail, 11, p.Secondary);
            detailText.FontFamily = new FontFamily("Cascadia Mono, Consolas");
            detailText.VerticalAlignment = VerticalAlignment.Center;
            detailText.Margin = new Thickness(8, 0, 0, 0);
            title.Children.Add(detailText);
        }
        UIElement? chip = null;
        if (page == PopupPage.Limits && !IsFaulty(entry) && state.Snapshot?.TightestWindow is { } tightest)
        {
            var color = p.SeverityBrush(tightest.Severity);
            chip = new Border
            {
                CornerRadius = new CornerRadius(9), BorderBrush = color, BorderThickness = new Thickness(1),
                Padding = new Thickness(7, 1, 7, 1),
                Child = Ui.Text(Format.Percent(tightest.Percent), 10.5, color, FontWeights.SemiBold),
            };
        }
        Ui.Add(column, Ui.Spread(title, chip, VerticalAlignment.Top), 16);

        if (page == PopupPage.Usage)
        {
            // Abo-Preis aller Konten zusammen – zwei Max-Abos sind 400 $, nicht 200 $.
            var prices = polledAccounts
                .Select(account => SubscriptionPrice.Dollars(provider.Kind, store.State(account.Id).Snapshot?.Account?.Plan))
                .OfType<int>().ToList();
            var view = new UsageView(Palette, consumption, provider.Kind, settings.ShowMoney,
                                     prices.Count > 0 ? prices.Sum() : null, period,
                                     selectedPeriod => Update(() => period = selectedPeriod), Math.Max(accountCount, 1));
            Ui.Add(column, view.Build(), 16);
        }
        else if (AccountProblem(entry) is { } problem)
        {
            Ui.Add(column, problem, 16);
        }
        else
        {
            foreach (var element in Limits(state, store.Loading.Contains(provider.Id)))
                Ui.Add(column, element, 16);
        }
        return column;
    }

    /// <summary>
    /// Seite eines Kontos, das sich nicht abfragen lässt (fehlender Ordner, Codex ohne Anmeldung) oder
    /// ohne Stand nur Fehler liefert: Hinweis und „Einstellungen öffnen“ statt leerer Balken.
    /// </summary>
    UIElement? AccountProblem(AccountEntry entry)
    {
        var p = Palette;
        var state = store.State(entry.Id);
        var folder = entry.Source.FolderDisplay ?? "";
        var kind = entry.Kind == "codex" ? AccountDiscovery.FolderKind.Codex : AccountDiscovery.FolderKind.Claude;
        string text;
        Severity severity;
        if (entry.Status == AccountStatus.MissingFolder)
            (text, severity) = ($"Ordner nicht gefunden: {folder}. Ist das Laufwerk eingehängt, erscheint das Konto von selbst wieder.", Severity.Crit);
        else if (entry.Status == AccountStatus.NotSignedIn && !entry.CanFetch)
            // Im Befehl der volle Pfad wie in den übrigen Windows-Hinweisen – PowerShell kennt kein %USERPROFILE%.
            (text, severity) = (kind.NotSignedInHint(entry.Source.Folder ?? ""), Severity.Warn);
        else if (state.Snapshot is null && state.Error is { } error && !state.IsRateLimited)
            (text, severity) = (error, Severity.Crit);
        else
            return null;

        var color = p.SeverityBrush(severity);
        var icon = Ui.Icon("\uE7BA", 11, color);
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 2, 0, 0);
        var label = Ui.Prose(text, 11, color, Ui.Font);
        label.Margin = new Thickness(6, 0, 0, 0);
        var hint = new Grid();
        hint.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        hint.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(label, 1);
        hint.Children.Add(icon);
        hint.Children.Add(label);

        var button = FooterButton(Ui.Text("Einstellungen öffnen", 11.5, p.Primary, FontWeights.SemiBold), "Einstellungen öffnen", openSettings);
        if (button is FrameworkElement element) element.HorizontalAlignment = HorizontalAlignment.Left;
        return Ui.Column(12, hint, button);
    }

    IEnumerable<UIElement> Limits(UsageStore.ProviderState state, bool isLoading)
    {
        var p = Palette;
        if (StatusLine(state) is { } status) yield return status;

        if (state.Snapshot is { } snapshot)
        {
            var meters = Ui.Column(18);
            foreach (var window in snapshot.Windows) Ui.Add(meters, MeterRow(window), 18);
            yield return meters;
            if (snapshot.Extras.Count > 0)
            {
                yield return Ui.Divider(p.Separator);
                var pills = new WrapPanel();
                foreach (var extra in snapshot.Extras)
                {
                    var text = Ui.Text(extra.Text, 11, p.Secondary);
                    text.FontFamily = new FontFamily("Cascadia Mono, Consolas");
                    pills.Children.Add(new Border
                    {
                        CornerRadius = new CornerRadius(6), Background = p.Fill,
                        Padding = new Thickness(9, 4, 9, 4), Margin = new Thickness(0, 0, 8, 4), Child = text,
                    });
                }
                yield return pills;
            }
        }
        else if (isLoading)
        {
            var loading = Ui.Text("Wird abgefragt …", 11, p.Secondary);
            loading.HorizontalAlignment = HorizontalAlignment.Center;
            loading.Margin = new Thickness(0, 20, 0, 20);
            yield return loading;
        }
    }

    /// <summary>Hinweis bei Rate-Limit, Fehler oder altem Stand – die letzten Werte bleiben darunter sichtbar.</summary>
    UIElement? StatusLine(UsageStore.ProviderState state)
    {
        var p = Palette;
        string glyph, text;
        Severity? severity;
        if (state.RetryAt is { } retryAt && state.IsRateLimited)
            (glyph, text, severity) = ("", $"Abfrage pausiert (Rate-Limit) · wieder ab {Format.Reset(retryAt, Now())}", Severity.Warn);
        else if (state.Error is { } error)
            (glyph, text, severity) = ("", state.Snapshot is null ? error : $"{error} Zeige letzten Stand.", Severity.Crit);
        else if (state.Note is { } note)
            (glyph, text, severity) = ("\uE917", state.Snapshot is { } snapshot ? $"{note} Abgefragt {Format.Ago(snapshot.FetchedAt, Now())}." : note, null);
        else
            return null;
        // Ein Hinweis ist kein Fehler: grau statt Warnfarbe.
        var color = severity is { } level ? p.SeverityBrush(level) : p.Secondary;
        var icon = Ui.Icon(glyph, 11, color);
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 2, 0, 0);
        var label = Ui.Prose(text, 11, color, Ui.Font);
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        label.Margin = new Thickness(6, 0, 0, 0);
        Grid.SetColumn(label, 1);
        grid.Children.Add(icon);
        grid.Children.Add(label);
        return grid;
    }

    /// <summary>Eine Meter-Zeile mit Balken, Pace-Marke und Reset-Zeit (SPEC §3.4).</summary>
    UIElement MeterRow(LimitWindow window)
    {
        var p = Palette;
        var now = Now();
        var elapsed = window.ElapsedFraction(now);
        var color = p.SeverityBrush(window.Severity);

        var name = new TextBlock { FontFamily = Ui.Font, TextTrimming = TextTrimming.CharacterEllipsis };
        name.Inlines.Add(new System.Windows.Documents.Run(window.Name) { FontSize = 12.5, FontWeight = FontWeights.SemiBold, Foreground = p.Primary });
        if (window.ScopeNote is { } note)
            name.Inlines.Add(new System.Windows.Documents.Run($"  {note}") { FontSize = 11, Foreground = p.Secondary });
        var top = Ui.Spread(name, Ui.Text(Format.Percent(window.Percent), 12.5, color, FontWeights.Bold), VerticalAlignment.Bottom);

        var bar = new MeterBar(window.Percent, elapsed, color, p.Fill, p.Primary);

        // Ollama nennt keine Reset-Zeiten – dann bleibt die Zeile weg statt leer.
        if (window.ResetsAt is null && elapsed is null) return Ui.Column(4, top, bar);

        UIElement reset = window.ResetsAt is { } resetsAt ? Ui.Text($"Reset {Format.Reset(resetsAt, now)}", 11, p.Secondary) : new Border();
        UIElement? pace = null;
        if (elapsed is { } e && window.WindowLength is { } length)
        {
            var onPace = Math.Abs(window.Percent - e) < Format.PaceTolerance;
            pace = Ui.Text(Format.Pace(window.Percent, e, length), 11, onPace ? p.Secondary : color,
                           onPace ? FontWeights.Normal : FontWeights.SemiBold);
        }
        return Ui.Column(4, top, bar, Ui.Spread(reset, pace));
    }
}

/// <summary>
/// Balken mit Pace-Marke; der Abstand zwischen Füllstand und Marke ist schraffiert (SPEC §3.4):
/// kräftig, wenn der Verbrauch der Zeit voraus ist, blass, wenn Kontingent liegen bleibt.
/// </summary>
public sealed class MeterBar : FrameworkElement
{
    const double BarHeight = 6;
    readonly double percent;
    readonly double? elapsed;
    readonly Brush color, track, marker;

    public MeterBar(double percent, double? elapsed, Brush color, Brush track, Brush marker)
    {
        this.percent = percent;
        this.elapsed = elapsed;
        this.color = color;
        this.track = track;
        this.marker = marker;
        Height = 10;
        SnapsToDevicePixels = true;
    }

    protected override void OnRender(DrawingContext context)
    {
        var width = ActualWidth;
        var top = (ActualHeight - BarHeight) / 2;
        var used = Math.Clamp(percent, 0, 1);
        var showGap = elapsed is { } value && Math.Abs(used - value) >= Format.PaceTolerance;

        var capsule = new RectangleGeometry(new Rect(0, top, width, BarHeight), BarHeight / 2, BarHeight / 2);
        context.PushClip(capsule);
        context.DrawRectangle(track, null, new Rect(0, top, width, BarHeight));
        context.DrawRectangle(color, null, new Rect(0, top, width * Math.Min(used, elapsed ?? used), BarHeight));
        if (elapsed is { } elapsedValue && showGap)
        {
            var ahead = used > elapsedValue;
            var gap = new Rect(width * Math.Min(used, elapsedValue), top, width * Math.Abs(used - elapsedValue), BarHeight);
            context.PushClip(new RectangleGeometry(gap));
            context.PushOpacity(ahead ? 1 : 0.6);
            if (ahead)
            {
                context.PushOpacity(0.55);
                context.DrawRectangle(color, null, gap);
                context.Pop();
            }
            // Diagonale Schraffur.
            var pen = new Pen(color, 1.5);
            for (var x = gap.Left - BarHeight; x < gap.Right; x += 4)
                context.DrawLine(pen, new Point(x, gap.Bottom), new Point(x + BarHeight, gap.Top));
            context.Pop();
            context.Pop();
        }
        context.Pop();

        if (elapsed is { } mark)
        {
            context.PushOpacity(0.45);
            context.DrawRectangle(marker, null, new Rect(width * mark - 1, 0, 2, ActualHeight));
            context.Pop();
        }
    }
}
