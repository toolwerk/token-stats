using System.Text.Json;
using System.Windows.Threading;
using TokenStats.Providers;

namespace TokenStats.Model;

/// <summary>
/// Hält den letzten Stand je Anbieter, fragt im Takt ab und respektiert Rate-Limits.
/// Läuft auf dem UI-Thread; <see cref="Changed"/> meldet jede Änderung.
/// </summary>
public sealed class UsageStore
{
    public sealed class ProviderState
    {
        public ProviderSnapshot? Snapshot { get; set; }
        public string? Error { get; set; }
        /// <summary>Hinweis ohne Fehlercharakter, z. B. „Stand der letzten »agy«-Sitzung“.</summary>
        public string? Note { get; set; }
        /// <summary>Letzte Anfrage, die tatsächlich an den Endpunkt ging – Basis für den Takt.</summary>
        public DateTimeOffset? LastAttempt { get; set; }
        /// <summary>Bis hierhin keine Abfrage – aus Retry-After nach HTTP 429.</summary>
        public DateTimeOffset? RetryAt { get; set; }

        public bool IsRateLimited => RetryAt is { } retryAt && retryAt > DateTimeOffset.UtcNow;
    }

    public sealed record Pick(string ProviderId, string ProviderName, LimitWindow Window);

    /// <summary>Abstand zwischen zwei manuellen Aktualisierungen.</summary>
    public static readonly TimeSpan ManualFloor = TimeSpan.FromSeconds(60);

    /// <summary>Alle erkannten Konten mit Zustand, auch ausgeblendete, fehlende und doppelte.</summary>
    public IReadOnlyList<AccountEntry> Entries { get; private set; }
    public Dictionary<string, ProviderState> States { get; private set; }
    public HashSet<string> Loading { get; } = [];

    public event Action? Changed;

    /// <summary>Konten höchstens so oft neu suchen (Ordnerliste + Kontodateien).</summary>
    static readonly TimeSpan DiscoveryInterval = TimeSpan.FromSeconds(60);

    readonly AppSettings settings;
    readonly string? cachePath;
    readonly Func<IReadOnlyList<AccountEntry>>? discover;
    DateTimeOffset lastDiscovery = DateTimeOffset.MinValue;
    bool isDemo;
    DispatcherTimer? timer;

    /// <summary>
    /// <paramref name="discover"/> findet die Konten neu (SPEC §6 „Mehrere Konten“) und ersetzt dann
    /// <paramref name="providers"/>; ohne bleibt die Liste fest, jedes Konto mit Zustand „ok“.
    /// </summary>
    public UsageStore(IReadOnlyList<IUsageProvider> providers, AppSettings settings, string? cachePath,
                      Func<IReadOnlyList<AccountEntry>>? discover = null)
    {
        this.settings = settings;
        this.cachePath = cachePath;
        this.discover = discover;
        Entries = discover?.Invoke() ?? providers.Select(provider => new AccountEntry(provider)).ToList();
        if (discover is not null) lastDiscovery = DateTimeOffset.UtcNow;
        States = LoadCache(cachePath);
    }

    /// <summary>Sucht die Konten neu; meldet nur, wenn sich wirklich etwas geändert hat.</summary>
    public void ReloadAccounts()
    {
        if (discover is null || isDemo) return;
        lastDiscovery = DateTimeOffset.UtcNow;
        var found = discover();
        static IEnumerable<(string, AccountSource, AccountStatus, string?)> Key(IEnumerable<AccountEntry> entries) =>
            entries.Select(entry => (entry.Id, entry.Source, entry.Status, entry.DuplicateOf));
        if (Key(found).SequenceEqual(Key(Entries))) return;
        Entries = found;
        Changed?.Invoke();
    }

    public ProviderState State(string id) => States.TryGetValue(id, out var state) ? state : new ProviderState();

    /// <summary>Eintrag zu einem Konto; bei doppelten IDs der eigentliche, nicht das Doppel.</summary>
    public AccountEntry? Entry(string id) =>
        Entries.FirstOrDefault(entry => entry.Id == id && entry.Status != AccountStatus.Duplicate)
        ?? Entries.FirstOrDefault(entry => entry.Id == id);

    /// <summary>
    /// Im Popup sichtbar: aufgeführt, nicht ausgeblendet, nicht doppelt – auch mit fehlendem Ordner
    /// oder ohne Anmeldung (dort grau mit „!“).
    /// </summary>
    public IEnumerable<AccountEntry> VisibleEntries =>
        Entries.Where(entry => entry.Status != AccountStatus.Duplicate && !settings.IsHidden(entry.Id) && entry.IsListed);

    /// <summary>Werden abgefragt: Quelle vorhanden, nicht ausgeblendet, nicht doppelt, Ordner da.</summary>
    public IEnumerable<IUsageProvider> PolledProviders =>
        Entries.Where(entry => entry.CanFetch && !settings.IsHidden(entry.Id)).Select(entry => entry.Provider);

    public bool IsPolled(IUsageProvider provider) => PolledProviders.Any(polled => polled.Id == provider.Id);

    /// <summary>
    /// Alphabetisch nach Anbieter, darin Standardkonto zuerst, dann nach Bezeichnung – damit die
    /// Tabs nicht springen (SPEC §3.2).
    /// </summary>
    public List<AccountEntry> SortedEntries
    {
        get
        {
            var comparer = StringComparer.Create(Format.Culture, ignoreCase: true);
            return VisibleEntries
                .OrderBy(entry => entry.Provider.DisplayName, comparer)
                .ThenBy(entry => entry.Provider.IsDefaultAccount ? 0 : 1)
                .ThenBy(entry => Label(entry.Provider) ?? "", comparer)
                .ToList();
        }
    }

    /// <summary>Sichtbare Konten, sortiert wie <see cref="SortedEntries"/>.</summary>
    public List<IUsageProvider> SortedProviders => SortedEntries.Select(entry => entry.Provider).ToList();

    /// <summary>Sichtbare Konten desselben Anbieters.</summary>
    public List<IUsageProvider> AccountsOfKind(string kind) => SortedProviders.Where(p => p.Kind == kind).ToList();

    /// <summary>Abgefragte Konten desselben Anbieters – Grundlage der Seite „Verbrauch“.</summary>
    public List<IUsageProvider> PolledAccountsOfKind(string kind) => AccountsOfKind(kind).Where(IsPolled).ToList();

    /// <summary>Bezeichnung des Kontos: eigene, sonst automatisch (E-Mail, Name, Ordner).</summary>
    public string? Label(IUsageProvider provider) =>
        settings.AccountLabels.TryGetValue(provider.Id, out var own) && !string.IsNullOrWhiteSpace(own)
            ? own
            : AutomaticLabel(provider)?.Text;

    /// <summary>Automatische Bezeichnung mit Herkunft – Platzhalter und Hinweis beim Umbenennen.</summary>
    public AutoLabel? AutomaticLabel(IUsageProvider provider)
    {
        if (provider.Source.AutomaticLabelInfo is { } label) return label;
        if (State(provider.Id).Snapshot?.Account?.Name is { } name
            && new AccountSource { Email = name.Contains('@') ? name : null, Name = name }.AutomaticLabelInfo is { } fromAccount)
            return fromAccount;
        return provider.IsDefaultAccount ? new AutoLabel("Standard", null) : null;
    }

    /// <summary>Bezeichnung nur, wenn der Anbieter mehrere sichtbare Konten hat.</summary>
    public string? AccountLabel(IUsageProvider provider) => AccountsOfKind(provider.Kind).Count > 1 ? Label(provider) : null;

    /// <summary>„Claude“ bei einem Konto, „Claude · Kunde A“ bei mehreren.</summary>
    public string Title(IUsageProvider provider) =>
        AccountLabel(provider) is { } label ? $"{provider.DisplayName} · {label}" : provider.DisplayName;

    /// <summary>Log-Ordner der abgefragten Konten, für die Verbrauchsseite – fehlende und doppelte bleiben außen vor.</summary>
    public Usage.UsageLedger.Roots LogRoots
    {
        get
        {
            var polled = PolledProviders.ToList();
            return new Usage.UsageLedger.Roots(
                polled.OfType<ClaudeProvider>().Select(p => p.ProjectsDirectory).ToList(),
                polled.OfType<CodexProvider>().Select(p => p.HomeDirectory).ToList());
        }
    }

    /// <summary>Wert für Tray-Symbol und Tooltip.</summary>
    public Pick? Displayed => (settings.FixedWindow is { } key ? PickFor(key) : null) ?? Tightest;

    public Pick? Tightest => TightestAmong(PolledProviders);

    /// <summary>Knappstes abgefragtes Konto eines Anbieters – Punkt im Anbieter-Tab, Auswahl beim Tab-Wechsel.</summary>
    public Pick? TightestOf(string kind) => TightestAmong(PolledProviders.Where(p => p.Kind == kind));

    Pick? TightestAmong(IEnumerable<IUsageProvider> providers) => providers
        .Select(p => State(p.Id).Snapshot?.TightestWindow is { } window ? new Pick(p.Id, Title(p), window) : null)
        .OfType<Pick>()
        .MaxBy(pick => pick.Window.Percent);

    public Pick? PickFor(string key)
    {
        var parts = key.Split('/', 2);
        if (parts.Length != 2) return null;
        var provider = PolledProviders.FirstOrDefault(p => p.Id == parts[0]);
        var window = provider is null ? null : State(provider.Id).Snapshot?.Windows.FirstOrDefault(w => w.Id == parts[1]);
        return window is null ? null : new Pick(provider!.Id, Title(provider), window);
    }

    public DateTimeOffset? LastUpdate => PolledProviders.Select(p => State(p.Id).Snapshot?.FetchedAt).Max();

    // Abruf

    public void Start()
    {
        ReloadAccounts();
        Refresh(manual: false);
        // Der Timer prüft nur, ob etwas fällig ist; der eigentliche Takt ist RefreshInterval.
        timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(30) };
        timer.Tick += (_, _) => Refresh(manual: false);
        timer.Start();
    }

    public void Refresh(bool manual)
    {
        // Demo-Stand bleibt fest: keine Abfrage, kein Reset-Rollover.
        if (isDemo) return;
        var now = DateTimeOffset.UtcNow;
        if (manual || now - lastDiscovery >= DiscoveryInterval) ReloadAccounts();
        RollOverResets(now);
        foreach (var provider in PolledProviders.Where(p => !Loading.Contains(p.Id)).ToList())
        {
            var state = State(provider.Id);
            if (state.IsRateLimited) continue;
            var spacing = manual ? ManualFloor : TimeSpan.FromSeconds(settings.RefreshInterval);
            if (state.LastAttempt is { } last && now - last < spacing) continue;
            _ = FetchAsync(provider);
        }
    }

    async Task FetchAsync(IUsageProvider provider)
    {
        var state = State(provider.Id);
        States[provider.Id] = state;
        Loading.Add(provider.Id);
        var previousAttempt = state.LastAttempt;
        state.LastAttempt = DateTimeOffset.UtcNow;
        Changed?.Invoke();
        try
        {
            state.Snapshot = await provider.FetchAsync();
            state.Error = null;
            state.Note = null;
            state.RetryAt = null;
        }
        catch (ProviderException error)
        {
            // Letzte Werte bleiben stehen, nie eine leere Anzeige.
            if (error.Kind == ProviderErrorKind.WaitingForToken)
            {
                state.Note = error.Message;
                state.Error = null;
            }
            else
            {
                state.Error = error.Message;
                state.Note = null;
            }
            // Ohne Anfrage kein Grund zu warten: Beim nächsten Timer-Tick werden die
            // Zugangsdaten neu gelesen, damit ein von der CLI erneuertes Token sofort greift.
            if (error.IsLocal) state.LastAttempt = previousAttempt;
            if (error.Kind == ProviderErrorKind.RateLimited)
                state.RetryAt = DateTimeOffset.UtcNow + (error.RetryAfter ?? TimeSpan.FromSeconds(settings.RefreshInterval));
        }
        catch (Exception error)
        {
            state.Error = error.Message;
        }
        Loading.Remove(provider.Id);
        SaveCache();
        Changed?.Invoke();
    }

    /// <summary>
    /// Ein Fenster, dessen Reset vorbei ist, steht ohne neue Abfrage auf 0 %. Wichtig für
    /// Anbieter, die nur selten abgefragt werden können (Antigravity), aber auch bei Rate-Limit.
    /// </summary>
    void RollOverResets(DateTimeOffset now)
    {
        var changed = false;
        foreach (var state in States.Values)
            foreach (var window in state.Snapshot?.Windows ?? [])
                changed |= window.RollOver(now);
        if (changed) Changed?.Invoke();
    }

    /// <summary>
    /// Nur für Screenshots: fester Stand, ohne Abruf und ohne den Cache zu überschreiben. Ohne
    /// <paramref name="entries"/> die vier Standardkonten als Demo-Konten (<see cref="DemoAccounts"/>):
    /// keine Erkennung, keine Kontodateien – so stimmt das Bild auch auf einem Rechner ohne Anmeldung.
    /// </summary>
    public void ShowDemo(Dictionary<string, ProviderSnapshot> snapshots, IReadOnlyList<AccountEntry>? entries = null,
                         IReadOnlyDictionary<string, string>? errors = null)
    {
        isDemo = true;
        timer?.Stop();
        Entries = entries ?? DemoAccounts.StandardEntries();
        States = snapshots.ToDictionary(pair => pair.Key, pair => new ProviderState { Snapshot = pair.Value });
        foreach (var (id, error) in errors ?? new Dictionary<string, string>())
        {
            if (!States.TryGetValue(id, out var state)) States[id] = state = new ProviderState();
            state.Error = error;
        }
        Changed?.Invoke();
    }

    // Cache
    // Nur Prozentwerte und Reset-Zeiten – keine Zugangsdaten. Überlebt Neustarts,
    // damit ein Neustart der App keine zusätzliche Abfrage auslöst.

    static Dictionary<string, ProviderState> LoadCache(string? path)
    {
        if (path is null) return [];
        try { return JsonSerializer.Deserialize<Dictionary<string, ProviderState>>(File.ReadAllText(path)) ?? []; }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { return []; }
    }

    void SaveCache()
    {
        if (cachePath is null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(cachePath)!);
            var temporary = cachePath + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(States));
            File.Move(temporary, cachePath, overwrite: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
}
