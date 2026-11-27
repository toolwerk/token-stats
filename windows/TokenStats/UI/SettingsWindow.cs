using System.Reflection;
using System.Windows;
using System.Windows.Controls;
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
        Content = Build();
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
    /// Abschnitt „Konten“ (SPEC §6 „Mehrere Konten je Anbieter“): erkannte Konten mit Schalter und
    /// Bezeichnung, dazu Ordner von Hand hinzufügen. Jede Änderung sucht die Konten neu.
    /// </summary>
    void Accounts(StackPanel root)
    {
        Section(root, "Konten");
        var list = new StackPanel();
        root.Children.Add(list);

        void Changed()
        {
            store.ReloadAccounts();
            store.Refresh(manual: false);
            consumption.Refresh();
            Fill();
        }

        void Fill()
        {
            list.Children.Clear();
            foreach (var provider in store.Providers.Where(p => p.IsInstalled()))
            {
                var grid = new Grid { Margin = new Thickness(0, 6, 0, 0) };
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                grid.ColumnDefinitions.Add(new ColumnDefinition());
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

                var id = provider.Id;
                var show = new CheckBox { IsChecked = !settings.IsHidden(id), VerticalAlignment = VerticalAlignment.Center, ToolTip = "Anzeigen" };
                show.Click += (_, _) =>
                {
                    settings.SetHidden(id, show.IsChecked != true);
                    Changed();
                };
                grid.Children.Add(show);

                var email = provider.Source.Email ?? store.State(id).Snapshot?.Account?.Name;
                var origin = provider.Source.FolderDisplay ?? (provider.IsDefaultAccount ? "Standard" : null);
                var text = new StackPanel { Margin = new Thickness(6, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
                text.Children.Add(new TextBlock { Text = provider.DisplayName + (email is null ? "" : $" · {email}"), TextTrimming = TextTrimming.CharacterEllipsis });
                if (origin is not null)
                    text.Children.Add(new TextBlock { Text = origin, FontSize = 12, Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis });
                Grid.SetColumn(text, 1);
                grid.Children.Add(text);

                var label = new TextBox
                {
                    Text = settings.AccountLabels.GetValueOrDefault(id) ?? "",
                    ToolTip = $"Bezeichnung (automatisch: {provider.Source.AutomaticLabel ?? "–"})",
                    VerticalAlignment = VerticalAlignment.Center,
                };
                label.LostFocus += (_, _) => settings.SetAccountLabel(id, label.Text);
                Grid.SetColumn(label, 2);
                grid.Children.Add(label);

                if (provider.Source is { Origin: AccountOrigin.Manual, Folder: { } folder })
                {
                    var kind = provider.Kind;
                    var remove = new Button { Content = "Entfernen", Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
                    remove.Click += (_, _) =>
                    {
                        settings.RemoveAccountFolder(kind, folder);
                        Changed();
                    };
                    Grid.SetColumn(remove, 3);
                    grid.Children.Add(remove);
                }
                list.Children.Add(grid);
            }
        }
        Fill();

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0) };
        foreach (var kind in AccountDiscovery.FolderKind.All)
        {
            var button = new Button { Content = $"{kind.DisplayName}-Ordner hinzufügen …", Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(8, 2, 8, 2) };
            button.Click += (_, _) =>
            {
                var dialog = new Microsoft.Win32.OpenFolderDialog
                {
                    Title = $"Ordner, den {kind.Variable} für das weitere Konto nennt",
                    InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                };
                if (dialog.ShowDialog(this) != true) return;
                settings.AddAccountFolder(kind.Id, dialog.FolderName);
                Changed();
            };
            buttons.Children.Add(button);
        }
        root.Children.Add(buttons);
        Note(root, "Weitere Konten legt die CLI mit eigenem Ordner an: CLAUDE_CONFIG_DIR bzw. CODEX_HOME. Ordner wie %USERPROFILE%\\.claude-2 werden automatisch gefunden. Ausgeblendete Konten werden nicht abgefragt.");
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
