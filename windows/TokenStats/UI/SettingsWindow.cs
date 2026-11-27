using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using TokenStats.Model;
using TokenStats.Providers;
using TokenStats.Usage;

namespace TokenStats.UI;

/// <summary>Einstellungsfenster, Abschnitte „Anzeige“, „Konten“, „Verbrauch“, „Aktualisierung“ und „Info“ (SPEC §4).</summary>
public sealed class SettingsWindow : Window
{
    static readonly double[] Intervals = [300, 600, 900, 1800, 3600];

    readonly AppSettings settings;
    readonly UsageStore store;
    readonly ConsumptionStore consumption;
    /// <summary>Farben der Hinweise im Abschnitt „Konten“.</summary>
    readonly Palette palette = new(SystemTheme.AppsDark);
    readonly StackPanel accountList = new();
    /// <summary>Konto, dessen Bezeichnung gerade bearbeitet wird.</summary>
    string? editingId;

    public SettingsWindow(AppSettings settings, UsageStore store, ConsumptionStore consumption)
    {
        this.settings = settings;
        this.store = store;
        this.consumption = consumption;

        Title = "Token Stats – Einstellungen";
        Width = 480;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        // Mit vielen Konten und Hinweisen wird das Fenster lang: dann scrollen statt über den Bildschirm hinaus.
        MaxHeight = SystemParameters.WorkArea.Height;
        Content = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = Build() };
    }

    UIElement Build()
    {
        var root = new StackPanel { Margin = new Thickness(24, 16, 24, 24) };

        Section(root, "Anzeige");
        // Auswahlliste statt Radiobuttons: Fluent gibt jedem RadioButton 120 px Mindestbreite, drei passen nicht in die Spalte.
        var modes = new ComboBox { MinWidth = 220 };
        foreach (var mode in MenuBarModes.All) modes.Items.Add(mode.Label());
        modes.SelectedIndex = Array.IndexOf(MenuBarModes.All, settings.MenuBarMode);
        modes.SelectionChanged += (_, _) => settings.MenuBarMode = MenuBarModes.All[modes.SelectedIndex];
        Field(root, "Tray-Symbol", modes);

        var windowChoice = new ComboBox { MinWidth = 220 };
        windowChoice.Items.Add(new ComboBoxItem { Content = "Knappstes Limit", Tag = null });
        foreach (var provider in store.SortedProviders)
            foreach (var window in store.State(provider.Id).Snapshot?.Windows ?? [])
                windowChoice.Items.Add(new ComboBoxItem { Content = $"{store.Title(provider)} · {window.Name}", Tag = $"{provider.Id}/{window.Id}" });
        windowChoice.SelectedItem = windowChoice.Items.Cast<ComboBoxItem>().FirstOrDefault(item => (string?)item.Tag == settings.FixedWindow)
                                    ?? windowChoice.Items[0];
        windowChoice.SelectionChanged += (_, _) => settings.FixedWindow = (string?)((ComboBoxItem)windowChoice.SelectedItem).Tag;
        Field(root, "Angezeigter Wert", windowChoice);

        Check(root, "Zustandsfarbe im Icon verwenden", settings.UseStateColor, value => settings.UseStateColor = value);
        Check(root, "API-Vergleichswert in Geld anzeigen", settings.ShowMoney, value => settings.ShowMoney = value);
        Check(root, "Bei Anmeldung starten", settings.LaunchAtLogin, value => settings.LaunchAtLogin = value);

        Accounts(root);

        Section(root, "Verbrauch");
        var billing = new ComboBox { MinWidth = 90 };
        for (var day = 1; day <= 31; day++) billing.Items.Add($"{day}.");
        billing.SelectedIndex = settings.BillingDay - 1;
        billing.SelectionChanged += (_, _) =>
        {
            settings.BillingDay = billing.SelectedIndex + 1;
            consumption.Refresh();
        };
        Field(root, "Stichtag des Abos", billing);
        Note(root, "Beginn des Zeitraums „Abrechnungsmonat“. In kürzeren Monaten gilt der Monatsletzte.");

        Section(root, "Aktualisierung");
        var interval = new ComboBox { MinWidth = 90 };
        foreach (var seconds in Intervals) interval.Items.Add($"{seconds / 60} Min.");
        interval.SelectedIndex = Math.Max(0, Array.IndexOf(Intervals, settings.RefreshInterval));
        interval.SelectionChanged += (_, _) => settings.RefreshInterval = Intervals[interval.SelectedIndex];
        Field(root, "Abfrageintervall", interval);
        Note(root, "Die Usage-Endpunkte sind hart rate-limitiert. Kürzer als 5 Minuten führt zu Fehlern.");

        Section(root, "Info");
        root.Children.Add(new TextBlock { Text = $"Version {Version}", Margin = new Thickness(0, 4, 0, 0) });
        Note(root, "Automatische Updates gibt es bisher nur in der macOS-Version. Neue Versionen: github.com/mahype/token-stats/releases");

        return root;
    }

    /// <summary>
    /// Abschnitt „Konten“ (SPEC §6 „Mehrere Konten je Anbieter“): Gruppen „Claude“, „Codex“ und „Weitere
    /// Anbieter“, je Konto Schalter, Herkunft, E-Mail, Ordner und Hinweise. Nichts wird gekürzt.
    /// </summary>
    void Accounts(StackPanel root)
    {
        Section(root, "Konten");
        root.Children.Add(accountList);
        FillAccounts();
        // PowerShell-Form wie die übrigen Windows-Hinweise; $env:USERPROFILE wird in "…" aufgelöst.
        // Die Befehle stehen als eigene Zeilen in Monospace (Ui.Prose).
        var footnote = Ui.Prose("Weitere Konten legst du mit eigenem Ordner an: »$env:CLAUDE_CONFIG_DIR=\"$env:USERPROFILE\\.claude-2\"; claude« bzw. "
                   + "»$env:CODEX_HOME=\"$env:USERPROFILE\\.codex-2\"; codex«. Ordner wie %USERPROFILE%\\.claude-2 findet Token Stats selbst. "
                   + "Ausgeblendete Konten werden nicht abgefragt.", 12);
        footnote.Opacity = 0.7;
        footnote.Margin = new Thickness(0, 6, 0, 0);
        root.Children.Add(footnote);
    }

    /// <summary>Jede Änderung an den Konten sucht sie neu, fragt fällige ab und liest den Verbrauch neu.</summary>
    void AccountsChanged()
    {
        store.ReloadAccounts();
        store.Refresh(manual: false);
        consumption.Refresh();
        FillAccounts();
    }

    void FillAccounts()
    {
        accountList.Children.Clear();
        var listed = store.Entries.Where(entry => entry.IsListed).ToList();
        var kinds = AccountDiscovery.FolderKind.All;
        bool HasFolders(AccountEntry entry) => kinds.Any(kind => kind.Id == entry.Kind);

        if (!listed.Any(HasFolders))
            accountList.Children.Add(EmptyAccounts());
        else
            foreach (var kind in kinds)
                accountList.Children.Add(AccountGroup(kind, listed.Where(entry => entry.Kind == kind.Id).ToList()));

        var others = listed.Where(entry => !HasFolders(entry)).ToList();
        if (others.Count > 0) accountList.Children.Add(OtherProviders(others));
    }

    UIElement EmptyAccounts()
    {
        var panel = new StackPanel { Margin = new Thickness(0, 6, 0, 0) };
        panel.Children.Add(new TextBlock { Text = "Noch kein Konto gefunden", FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(new TextBlock
        {
            Text = "Melde dich in Claude Code oder Codex an. Liegt eine Anmeldung in einem anderen Ordner, füge ihn hier hinzu.",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.7,
            Margin = new Thickness(0, 4, 0, 0),
        });
        var buttons = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        foreach (var kind in AccountDiscovery.FolderKind.All)
        {
            var button = AddFolderButton(kind);
            button.Margin = new Thickness(0, 0, 8, 4);
            buttons.Children.Add(button);
        }
        panel.Children.Add(buttons);
        return panel;
    }

    UIElement AccountGroup(AccountDiscovery.FolderKind kind, List<AccountEntry> entries)
    {
        var group = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        group.Children.Add(GroupHeading(kind.DisplayName));
        foreach (var entry in entries.Where(e => e.Status != AccountStatus.Duplicate))
            group.Children.Add(AccountRow(kind, entry));
        // Doppelte Ordner als Info-Zeilen unter den Konten der Gruppe.
        foreach (var entry in entries.Where(e => e.Status == AccountStatus.Duplicate))
            group.Children.Add(DuplicateRow(kind, entry));
        var add = AddFolderButton(kind);
        add.HorizontalAlignment = HorizontalAlignment.Right;
        add.Margin = new Thickness(0, 10, 0, 0);
        group.Children.Add(add);
        return group;
    }

    static TextBlock GroupHeading(string text) => new()
    {
        Text = text.ToUpper(Format.Culture),
        FontSize = 11,
        FontWeight = FontWeights.SemiBold,
        Opacity = 0.65,
        Margin = new Thickness(0, 8, 0, 0),
    };

    /// <summary>Eine Zeile je Konto: Schalter mit Bezeichnung, Herkunft, E-Mail, Ordner, Hinweise; rechts Stift und „Entfernen“.</summary>
    UIElement AccountRow(AccountDiscovery.FolderKind kind, AccountEntry entry)
    {
        var id = entry.Id;
        var provider = entry.Provider;
        var missing = entry.Status == AccountStatus.MissingFolder;
        var hidden = settings.IsHidden(id);
        var editing = editingId == id && !missing;

        var grid = new Grid { Margin = new Thickness(0, 10, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var text = new StackPanel();
        if (editing)
        {
            text.Children.Add(LabelEditor(entry));
        }
        else
        {
            // Angehakt = anzeigen; ein Klick auf den Namen schaltet mit.
            var label = store.Label(provider) ?? provider.DisplayName;
            var show = new CheckBox
            {
                // Deaktiviert (Ordner fehlt) wäre die Beschriftung grau: Dann steht der Name daneben in
                // der normalen Schrift, und die Checkbox trägt ihn nur für Screenreader.
                Content = missing ? null : Wrapped(label),
                // Fehlt der Ordner: leer und deaktiviert, ob ausgeblendet oder nicht.
                IsChecked = entry.ShowsAsChecked(hidden),
                IsEnabled = !missing,
                ToolTip = "Anzeigen",
                MinWidth = 0,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 8, 0),
            };
            show.Click += (_, _) =>
            {
                settings.SetHidden(id, show.IsChecked != true);
                AccountsChanged();
            };
            System.Windows.Automation.AutomationProperties.SetName(show, label);
            var badge = Badge(entry.Source.Origin switch
            {
                AccountOrigin.Standard => "Standard",
                AccountOrigin.Detected => "automatisch gefunden",
                _ => "von Hand",
            });
            if (missing)
            {
                // Kästchen links, daneben Name und Abzeichen; der Name bricht neben dem Kästchen um.
                show.Margin = new Thickness(0);
                show.VerticalAlignment = VerticalAlignment.Top;
                DockPanel.SetDock(show, Dock.Left);
                var nameText = Wrapped(label);
                nameText.VerticalAlignment = VerticalAlignment.Center;
                nameText.Margin = new Thickness(0, 0, 8, 0);
                var labels = new WrapPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
                labels.Children.Add(nameText);
                labels.Children.Add(badge);
                var row = new DockPanel { LastChildFill = true };
                row.Children.Add(show);
                row.Children.Add(labels);
                text.Children.Add(row);
            }
            else
            {
                var name = new WrapPanel();
                name.Children.Add(show);
                name.Children.Add(badge);
                text.Children.Add(name);
            }
        }

        // E-Mail aus der Kontodatei, sonst aus dem letzten Abruf (Codex nennt dort die E-Mail).
        var snapshotName = store.State(id).Snapshot?.Account?.Name;
        var email = entry.Source.Email ?? (snapshotName is not null && snapshotName.Contains('@') ? snapshotName : null);
        if (email is not null) text.Children.Add(Secondary(email, indent: true));
        var folder = Secondary(FolderText(kind, entry), indent: true);
        folder.FontFamily = new FontFamily("Cascadia Mono, Consolas");
        text.Children.Add(folder);
        if (hidden) text.Children.Add(Secondary("Ausgeblendet, wird nicht abgefragt.", indent: true));

        if (missing)
            text.Children.Add(Hint(AccountEntry.MissingFolderHint(hidden), Severity.Crit));
        else if (entry.Status == AccountStatus.NotSignedIn)
            // Im Befehl der volle Pfad wie in den übrigen Windows-Hinweisen – PowerShell kennt kein %USERPROFILE%.
            text.Children.Add(Hint(kind.NotSignedInHint(entry.Source.Folder ?? ""), Severity.Warn));
        grid.Children.Add(text);

        var buttons = Buttons(RemoveButton(kind, entry), PenButton(id, visible: !missing && !editing));
        Grid.SetColumn(buttons, 1);
        grid.Children.Add(buttons);
        return grid;
    }

    /// <summary>
    /// Knöpfe rechts in jeder Zeile gleich: zuerst „Entfernen“ (nur „von Hand“), ganz rechts der Stift.
    /// Ein unsichtbarer Stift hält seinen Platz, damit „Entfernen“ überall an derselben Stelle sitzt.
    /// </summary>
    static StackPanel Buttons(Button? remove, Button pen)
    {
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(8, 0, 0, 0) };
        if (remove is not null)
        {
            remove.Margin = new Thickness(0, 0, 6, 0);
            buttons.Children.Add(remove);
        }
        buttons.Children.Add(pen);
        return buttons;
    }

    /// <summary>Stift „Bezeichnung ändern“; <paramref name="visible"/> = false hält nur den Platz frei.</summary>
    Button PenButton(string id, bool visible)
    {
        var pen = new Button
        {
            Content = new TextBlock { Text = "\uE70F", FontFamily = Ui.Icons, FontSize = 12 },
            ToolTip = "Bezeichnung ändern",
            MinWidth = 0,
            Padding = new Thickness(8, 4, 8, 4),
            VerticalAlignment = VerticalAlignment.Top,
            // Hidden statt Collapsed: unsichtbar, nicht bedienbar, aber mit Platz.
            Visibility = visible ? Visibility.Visible : Visibility.Hidden,
        };
        pen.Click += (_, _) =>
        {
            editingId = id;
            FillAccounts();
        };
        return pen;
    }

    /// <summary>
    /// Bezeichnung bearbeiten: Feld über die volle Breite mit der automatischen Bezeichnung als
    /// Platzhalter, „Fertig“ (Enter) übernimmt, Esc bricht ab. Leer = automatische Bezeichnung.
    /// </summary>
    UIElement LabelEditor(AccountEntry entry)
    {
        var id = entry.Id;
        var automatic = store.AutomaticLabel(entry.Provider);
        var own = settings.AccountLabels.GetValueOrDefault(id) ?? "";

        var box = new TextBox
        {
            Text = own,
            MaxLength = AppSettings.MaxAccountLabelLength,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        // Echter Platzhalter: TextBox kennt keinen, darum ein Text darüber, der Klicks durchlässt.
        var placeholder = new TextBlock
        {
            Text = automatic?.Text ?? "",
            IsHitTestVisible = false,
            Opacity = 0.5,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(11, 0, 0, 0),
            TextTrimming = TextTrimming.None,
        };
        var field = new Grid();
        field.Children.Add(box);
        field.Children.Add(placeholder);

        var done = new Button { Content = "Fertig", MinWidth = 0, Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        var line = new Grid();
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(done, 1);
        line.Children.Add(field);
        line.Children.Add(done);

        var hint = Secondary(automatic is { Origin: { } origin }
            ? $"Leer lassen für „{automatic.Text}“ ({origin.Description()}). Höchstens {AppSettings.MaxAccountLabelLength} Zeichen."
            : $"Höchstens {AppSettings.MaxAccountLabelLength} Zeichen.", indent: false);
        var longWords = Secondary("Lange Wörter mit Leerzeichen oder Bindestrich trennen, dann bleibt die Bezeichnung im kleinen Widget lesbar.", indent: false);

        void UpdateHints()
        {
            placeholder.Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            longWords.Visibility = HasLongWord(box.Text) ? Visibility.Visible : Visibility.Collapsed;
        }
        UpdateHints();
        box.TextChanged += (_, _) => UpdateHints();

        void Finish(bool save)
        {
            // Unverändert nichts speichern – sonst würde ein älterer, längerer Wert gekürzt.
            if (save && box.Text != own) settings.SetAccountLabel(id, box.Text);
            editingId = null;
            FillAccounts();
        }
        done.Click += (_, _) => Finish(save: true);
        box.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter)
            {
                e.Handled = true;
                Finish(save: true);
            }
            else if (e.Key == Key.Escape)
            {
                e.Handled = true;
                Finish(save: false);
            }
        };
        box.Loaded += (_, _) =>
        {
            box.Focus();
            box.SelectAll();
        };

        var panel = new StackPanel();
        panel.Children.Add(line);
        panel.Children.Add(hint);
        panel.Children.Add(longWords);
        return panel;
    }

    /// <summary>Wort mit mehr als 14 Zeichen – bricht im kleinen Widget schlecht um.</summary>
    static bool HasLongWord(string text) =>
        text.Split(new[] { ' ', '-', '\t' }, StringSplitOptions.RemoveEmptyEntries).Any(word => word.Length > 14);

    /// <summary>Doppelter Ordner: Info statt stillem Verwerfen, bei „von Hand“ mit „Entfernen“.</summary>
    UIElement DuplicateRow(AccountDiscovery.FolderKind kind, AccountEntry entry)
    {
        var other = entry.DuplicateOf is { } otherId ? store.Entry(otherId) : null;
        var otherLabel = other is null ? entry.DuplicateOf ?? "" : store.Label(other.Provider) ?? other.Provider.DisplayName;
        var grid = new Grid { Margin = new Thickness(0, 10, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var info = Hint($"{FolderText(kind, entry)} gehört zum selben Konto wie „{otherLabel}“ und wird nicht doppelt gezeigt.", severity: null);
        info.Margin = new Thickness(0);
        grid.Children.Add(info);
        if (RemoveButton(kind, entry) is { } remove)
        {
            // Gleiche Stelle wie in den Kontozeilen: Platz für den Stift bleibt frei.
            var buttons = Buttons(remove, PenButton(entry.Id, visible: false));
            Grid.SetColumn(buttons, 1);
            grid.Children.Add(buttons);
        }
        return grid;
    }

    /// <summary>„Entfernen“ gibt es nur für Ordner „von Hand“.</summary>
    Button? RemoveButton(AccountDiscovery.FolderKind kind, AccountEntry entry)
    {
        if (entry.Source is not { Origin: AccountOrigin.Manual, Folder: { } folder }) return null;
        var id = entry.Id;
        var remove = new Button { Content = "Entfernen", MinWidth = 0, Padding = new Thickness(10, 4, 10, 4), VerticalAlignment = VerticalAlignment.Top };
        remove.Click += (_, _) =>
        {
            if (editingId == id) editingId = null;
            settings.RemoveAccountFolder(kind.Id, folder);
            AccountsChanged();
        };
        return remove;
    }

    UIElement OtherProviders(List<AccountEntry> entries)
    {
        var group = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        group.Children.Add(GroupHeading("Weitere Anbieter"));
        foreach (var entry in entries)
        {
            var id = entry.Id;
            var row = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
            var show = new CheckBox
            {
                Content = Wrapped(entry.Provider.DisplayName),
                IsChecked = !settings.IsHidden(id),
                ToolTip = "Anzeigen",
                MinWidth = 0,
                HorizontalAlignment = HorizontalAlignment.Left,
            };
            show.Click += (_, _) =>
            {
                settings.SetHidden(id, show.IsChecked != true);
                AccountsChanged();
            };
            row.Children.Add(show);
            row.Children.Add(Secondary("Eine Quelle je Rechner, keine weiteren Konten möglich.", indent: true));
            if (settings.IsHidden(id)) row.Children.Add(Secondary("Ausgeblendet, wird nicht abgefragt.", indent: true));
            group.Children.Add(row);
        }
        return group;
    }

    Button AddFolderButton(AccountDiscovery.FolderKind kind)
    {
        var button = new Button { Content = $"{kind.DisplayName}-Ordner hinzufügen …", Padding = new Thickness(8, 2, 8, 2) };
        button.Click += (_, _) =>
        {
            var dialog = new Microsoft.Win32.OpenFolderDialog
            {
                Title = $"Ordner, den {kind.Variable} für das weitere Konto nennt",
                InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            };
            if (dialog.ShowDialog(this) != true) return;
            // Erscheint sofort als Zeile – mit Hinweis, falls doppelt oder ohne Anmeldung.
            settings.AddAccountFolder(kind.Id, dialog.FolderName);
            AccountsChanged();
        };
        return button;
    }

    /// <summary>Ordner in Anzeigeform; beim Standardkonto der feste Ordner im Profil.</summary>
    static string FolderText(AccountDiscovery.FolderKind kind, AccountEntry entry) =>
        entry.Source.FolderDisplay
        ?? AccountSource.Display(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), kind.StandardFolder));

    static TextBlock Wrapped(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap };

    /// <summary>Sekundäre Zeile unter dem Namen; <paramref name="indent"/> rückt sie bis unter den Text der Checkbox ein.</summary>
    static TextBlock Secondary(string text, bool indent) => new()
    {
        Text = text,
        FontSize = 12,
        Opacity = 0.7,
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(indent ? CheckIndent : 0, 3, 0, 0),
    };

    /// <summary>Abstand vom linken Rand der Checkbox bis zu ihrem Text (Fluent: 20 px Kästchen + 8 px Abstand).</summary>
    const double CheckIndent = 28;

    /// <summary>Herkunfts-Abzeichen neben dem Namen.</summary>
    static Border Badge(string text) => new()
    {
        CornerRadius = new CornerRadius(4),
        Padding = new Thickness(6, 1, 6, 2),
        Background = Palette.Solid(0x808080, 0x30),
        VerticalAlignment = VerticalAlignment.Center,
        Child = new TextBlock { Text = text, FontSize = 11, TextWrapping = TextWrapping.Wrap },
    };

    /// <summary>Hinweis in der Zeile, eigene Fläche: rot/gelb mit Warndreieck, ohne Stufe grau mit Info-Symbol.</summary>
    Border Hint(string text, Severity? severity)
    {
        var rgb = severity is { } level ? Palette.SeverityColor(level, palette.IsDark) : 0x808080;
        var icon = new TextBlock
        {
            Text = severity is null ? "\uE946" : "\uE7BA",
            FontFamily = Ui.Icons,
            FontSize = 12,
            Foreground = severity is null ? palette.Secondary : palette.SeverityBrush(severity.Value),
            Margin = new Thickness(0, 2, 8, 0),
            VerticalAlignment = VerticalAlignment.Top,
        };
        // Fehler in eigener Textfarbe (mindestens 4,5 : 1 auf der Fläche), sonst die Fensterschrift.
        var label = Ui.Prose(text, 12, severity == Severity.Crit ? palette.SeverityTextBrush(Severity.Crit) : null);
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(label, 1);
        grid.Children.Add(icon);
        grid.Children.Add(label);
        return new Border
        {
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(8, 6, 8, 6),
            Margin = new Thickness(CheckIndent, 6, 0, 0),
            Background = Palette.Solid(rgb, 0x26),
            Child = grid,
        };
    }

    static string Version =>
        Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "?";

    static void Section(StackPanel root, string title) => root.Children.Add(new TextBlock
    {
        Text = title,
        FontSize = 14,
        FontWeight = FontWeights.SemiBold,
        Margin = new Thickness(0, root.Children.Count == 0 ? 0 : 20, 0, 6),
    });

    static void Field(StackPanel root, string label, FrameworkElement control)
    {
        var grid = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        var text = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center };
        control.HorizontalAlignment = HorizontalAlignment.Left;
        control.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 1);
        grid.Children.Add(text);
        grid.Children.Add(control);
        root.Children.Add(grid);
    }

    static void Check(StackPanel root, string label, bool value, Action<bool> set)
    {
        var box = new CheckBox { Content = label, IsChecked = value, Margin = new Thickness(0, 6, 0, 0) };
        box.Click += (_, _) => set(box.IsChecked == true);
        root.Children.Add(box);
    }

    static void Note(StackPanel root, string text) => root.Children.Add(new TextBlock
    {
        Text = text,
        FontSize = 12,
        Opacity = 0.7,
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(0, 6, 0, 0),
    });
}
