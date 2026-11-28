using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace TokenStats.Model;

public enum MenuBarMode { Icon, IconPercent, IconBars }

public static class MenuBarModes
{
    public static readonly MenuBarMode[] All = [MenuBarMode.Icon, MenuBarMode.IconPercent, MenuBarMode.IconBars];

    public static string Label(this MenuBarMode mode) => mode switch
    {
        MenuBarMode.Icon => "Nur Icon",
        MenuBarMode.IconPercent => "Icon + %",
        _ => "Icon + Balken",
    };
}

/// <summary>Einstellungen, als JSON unter %LOCALAPPDATA%\TokenStats gespeichert.</summary>
public sealed class AppSettings
{
    public const double MinimumInterval = 300;

    sealed class Stored
    {
        public MenuBarMode MenuBarMode { get; set; } = MenuBarMode.Icon;
        public string? FixedWindow { get; set; }
        public bool UseStateColor { get; set; } = true;
        public double RefreshInterval { get; set; } = MinimumInterval;
        public bool ShowMoney { get; set; } = true;
        public int BillingDay { get; set; } = 1;
        public Dictionary<string, string> AccountLabels { get; set; } = [];
        public List<string> HiddenAccounts { get; set; } = [];
        public Dictionary<string, List<string>> AccountFolders { get; set; } = [];
    }

    static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    readonly Stored stored;
    readonly string? path;

    public event Action? Changed;

    public AppSettings(string? path = null)
    {
        this.path = path;
        stored = Load(path) ?? new Stored();
        stored.RefreshInterval = Math.Max(stored.RefreshInterval, MinimumInterval);
        stored.BillingDay = Math.Clamp(stored.BillingDay, 1, 31);
    }

    public MenuBarMode MenuBarMode { get => stored.MenuBarMode; set => Set(() => stored.MenuBarMode = value); }

    /// <summary><c>null</c> = knappstes Limit, sonst "providerID/windowID".</summary>
    public string? FixedWindow { get => stored.FixedWindow; set => Set(() => stored.FixedWindow = value); }

    public bool UseStateColor { get => stored.UseStateColor; set => Set(() => stored.UseStateColor = value); }

    /// <summary>Abfrageintervall in Sekunden, nie unter 300 (Endpunkte sind hart rate-limitiert).</summary>
    public double RefreshInterval
    {
        get => stored.RefreshInterval;
        set => Set(() => stored.RefreshInterval = Math.Max(value, MinimumInterval));
    }

    /// <summary>API-Vergleichswert in Geld zeigen; aus = reine Token-Seite (SPEC §4).</summary>
    public bool ShowMoney { get => stored.ShowMoney; set => Set(() => stored.ShowMoney = value); }

    /// <summary>Stichtag des Abos für den Zeitraum „Abrechnungsmonat“.</summary>
    public int BillingDay { get => stored.BillingDay; set => Set(() => stored.BillingDay = Math.Clamp(value, 1, 31)); }

    // Konten (SPEC §6 „Mehrere Konten je Anbieter“)

    /// <summary>Eigene Bezeichnungen der Konten, Konto-ID → Text.</summary>
    public IReadOnlyDictionary<string, string> AccountLabels => stored.AccountLabels;

    public void SetAccountLabel(string id, string? label) => Set(() =>
    {
        if (string.IsNullOrWhiteSpace(label)) stored.AccountLabels.Remove(id);
        else stored.AccountLabels[id] = label.Trim();
    });

    /// <summary>Ausgeblendete Konten: nicht abgefragt, nicht angezeigt, nicht im Verbrauch.</summary>
    public bool IsHidden(string id) => stored.HiddenAccounts.Contains(id);

    public void SetHidden(string id, bool hidden) => Set(() =>
    {
        stored.HiddenAccounts.Remove(id);
        if (hidden) stored.HiddenAccounts.Add(id);
    });

    /// <summary>Von Hand hinzugefügte Konfigurationsordner, Anbieter-ID → Pfade.</summary>
    public IReadOnlyDictionary<string, List<string>> AccountFolders => stored.AccountFolders;

    public void AddAccountFolder(string kind, string path) => Set(() =>
    {
        var folders = stored.AccountFolders.TryGetValue(kind, out var list) ? list : stored.AccountFolders[kind] = [];
        if (!folders.Contains(path, StringComparer.OrdinalIgnoreCase)) folders.Add(path);
    });

    public void RemoveAccountFolder(string kind, string path) => Set(() =>
    {
        if (!stored.AccountFolders.TryGetValue(kind, out var folders)) return;
        folders.RemoveAll(folder => string.Equals(Path.GetFullPath(folder).TrimEnd(Path.DirectorySeparatorChar), path, StringComparison.OrdinalIgnoreCase));
        if (folders.Count == 0) stored.AccountFolders.Remove(kind);
    });

    void Set(Action change)
    {
        change();
        Save();
        Changed?.Invoke();
    }

    static Stored? Load(string? path)
    {
        if (path is null) return null;
        try { return JsonSerializer.Deserialize<Stored>(File.ReadAllText(path), JsonOptions); }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { return null; }
    }

    void Save()
    {
        if (path is null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, JsonSerializer.Serialize(stored, JsonOptions));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    // Bei Anmeldung starten – Zustand liegt im Run-Schlüssel der Registry, nicht in der Datei.

    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string RunValue = "TokenStats";

    public bool LaunchAtLogin
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(RunValue) is string command
                && string.Equals(command.Trim('"'), Environment.ProcessPath, StringComparison.OrdinalIgnoreCase);
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue(RunValue, $"\"{Environment.ProcessPath}\"");
            else key.DeleteValue(RunValue, throwOnMissingValue: false);
            Changed?.Invoke();
        }
    }
}
