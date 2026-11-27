using TokenStats.Model;

namespace TokenStats.Providers;

/// <summary>
/// Erfundenes Konto für Screenshots und Tests (wie <c>DemoAccountProvider</c> auf dem Mac): fragt nichts
/// ab und liest keine Dateien – weder Zugangsdaten noch <c>.claude.json</c>, also nie echte Namen oder Adressen.
/// </summary>
public sealed class DemoAccountProvider(string id, string kind, string displayName, AccountSource source, bool installed) : IUsageProvider
{
    public string Id => id;
    public string Kind => kind;
    public string DisplayName => displayName;
    public AccountSource Source => source;
    public bool IsInstalled() => installed;
    public Task<ProviderSnapshot> FetchAsync() => Task.FromException<ProviderSnapshot>(ProviderException.NotLoggedIn("Demo-Konto"));
}

/// <summary>
/// Demo-Konten für mehrere Konten je Anbieter (SPEC §6), nach <c>DemoAccounts</c> in TokenStatsCore:
/// Bezeichnungen wie im Designer-Entwurf, Adressen unter <c>example.com</c>, keine echten Limits,
/// Ordner oder Kontonamen. Ordner im Profil stehen in der Anzeige als <c>%USERPROFILE%\…</c>; Ordner,
/// deren voller Pfad in einem Hinweis steht, liegen darum außerhalb des Profils (<c>D:\…</c>).
/// </summary>
public static class DemoAccounts
{
    /// <summary>
    /// <see cref="Multi"/>: 3 × Claude + Codex. <see cref="Invalid"/>: fehlender Ordner, Ordner ohne
    /// Anmeldung, doppelte Anmeldung, abgemeldetes Konto. <see cref="Errors"/>: Abruffehler ohne Stand.
    /// </summary>
    public enum Scenario { Multi, Invalid, Errors }

    public sealed record Account
    {
        public required string Id { get; init; }
        public required string Kind { get; init; }
        public required string KindName { get; init; }
        public AccountOrigin Origin { get; init; } = AccountOrigin.Standard;
        /// <summary>Voller Pfad; <c>null</c> beim Standardkonto und bei Anbietern mit fester Quelle.</summary>
        public string? Folder { get; init; }
        /// <summary>Eigene Bezeichnung; <c>null</c> = automatisch.</summary>
        public string? Label { get; init; }
        public string? Email { get; init; }
        public AccountStatus Status { get; init; } = AccountStatus.Ok;
        public string? DuplicateOf { get; init; }
        public bool Hidden { get; init; }
        public ProviderSnapshot? Snapshot { get; init; }
        /// <summary>Fehlertext der Abfrage, wie ihn <see cref="ProviderException"/> liefert.</summary>
        public string? Error { get; init; }

        /// <summary>Eintrag der Kontenliste; fehlender Ordner und Ordner ohne Anmeldung zählen wie auf dem Mac als nicht vorhanden.</summary>
        public AccountEntry Entry() => new(
            new DemoAccountProvider(Id, Kind, KindName, new AccountSource { Folder = Folder, Origin = Origin, Email = Email },
                                    installed: Status is not (AccountStatus.MissingFolder or AccountStatus.NotSignedIn)),
            Status, DuplicateOf);
    }

    /// <summary>Die vier Standardkonten ohne Bezeichnung und Adresse – für die übrigen Screenshots.</summary>
    public static List<AccountEntry> StandardEntries() =>
    [
        .. new[] { ("claude", "Claude"), ("codex", "Codex"), ("antigravity", "Antigravity"), ("ollama", "Ollama") }
            .Select(kind => new AccountEntry(new DemoAccountProvider(kind.Item1, kind.Item1, kind.Item2, new AccountSource(), installed: true))),
    ];

    /// <summary>Konto-ID von „Kunde A“ – im Zustand <see cref="Scenario.Invalid"/> mit fehlendem Ordner, in <see cref="Scenario.Errors"/> mit HTTP 503.</summary>
    public const string KundeA = "claude@e5f6a7b8";
    /// <summary>Konto-ID von „Arbeit“ – in <see cref="Scenario.Errors"/> nicht angemeldet.</summary>
    public const string Arbeit = "claude@a1b2c3d4";

    /// <summary>Fehler „Nicht angemeldet“ wie von <see cref="ClaudeProvider"/>, mit <c>$env:USERPROFILE</c> statt des echten Profilpfads.</summary>
    public static readonly string SignedOutError =
        ProviderException.NotLoggedIn("»$env:CLAUDE_CONFIG_DIR=\"$env:USERPROFILE\\.claude-arbeit\"; claude« im Terminal einmal starten.").Message;

    /// <summary>„Server antwortet mit HTTP 503.“ – derselbe Text wie bei einem echten Abruf.</summary>
    public static readonly string ServerError = ProviderException.Http(503).Message;

    /// <param name="standard">Stände von Codex, Antigravity und Ollama (Demo-Werte der Screenshots).</param>
    public static List<Account> Accounts(Scenario scenario, DateTimeOffset now, IReadOnlyDictionary<string, ProviderSnapshot> standard)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var codex = new Account
        {
            Id = "codex", Kind = "codex", KindName = "Codex", Label = "Privat", Email = "codex@example.com",
            Snapshot = standard.GetValueOrDefault("codex"),
        };
        Account[] others =
        [
            new() { Id = "antigravity", Kind = "antigravity", KindName = "Antigravity", Snapshot = standard.GetValueOrDefault("antigravity") },
            new() { Id = "ollama", Kind = "ollama", KindName = "Ollama", Snapshot = standard.GetValueOrDefault("ollama") },
        ];
        var privat = Claude("claude", "Privat", null, AccountOrigin.Standard, 0.42, 0.82, now);
        var arbeit = Claude(Arbeit, "Arbeit", Path.Combine(home, ".claude-arbeit"), AccountOrigin.Detected, 0.24, 0.51, now);
        var kundeA = Claude(KundeA, "Kunde A", @"D:\Kunden\kunde-a", AccountOrigin.Manual, 0.67, 1.0, now, plan: "Pro");

        return scenario switch
        {
            Scenario.Multi => [privat, arbeit, kundeA, codex, .. others],
            Scenario.Invalid =>
            [
                privat,
                arbeit with { Snapshot = null, Error = SignedOutError },
                kundeA with { Snapshot = null, Status = AccountStatus.MissingFolder },
                // Ohne Anmeldung und ohne Adresse: Bezeichnung aus dem Ordnernamen.
                new() { Id = "claude@c0ffee00", Kind = "claude", KindName = "Claude", Origin = AccountOrigin.Manual, Folder = @"D:\claude-alt",
                        Status = AccountStatus.NotSignedIn },
                new() { Id = "claude@d00dfeed", Kind = "claude", KindName = "Claude", Origin = AccountOrigin.Detected,
                        Folder = Path.Combine(home, ".claude-kopie"), Email = "privat@example.com",
                        Status = AccountStatus.Duplicate, DuplicateOf = "claude" },
                codex, .. others,
            ],
            _ =>
            [
                privat,
                arbeit with { Snapshot = null, Error = SignedOutError },
                kundeA with { Snapshot = null, Error = ServerError },
                codex, .. others,
            ],
        };
    }

    /// <summary>
    /// Zeigt die Konten im Store: Einträge, Stände und Fehler; Bezeichnungen und Ausblenden über
    /// <paramref name="settings"/> – die müssen ohne Pfad angelegt sein (<c>new AppSettings()</c>), dann
    /// wirkt beides nur im Speicher.
    /// </summary>
    public static void Show(UsageStore store, AppSettings settings, IReadOnlyList<Account> accounts)
    {
        foreach (var account in accounts)
        {
            if (account.Label is { } label) settings.SetAccountLabel(account.Id, label);
            if (account.Hidden) settings.SetHidden(account.Id, true);
        }
        store.ShowDemo(
            accounts.Where(account => account.Snapshot is not null).ToDictionary(account => account.Id, account => account.Snapshot!),
            accounts.Select(account => account.Entry()).ToList(),
            accounts.Where(account => account.Error is not null).ToDictionary(account => account.Id, account => account.Error!));
    }

    static Account Claude(string id, string label, string? folder, AccountOrigin origin, double session, double week,
                          DateTimeOffset now, string plan = "Max 20×")
    {
        const double hour = 3600;
        return new Account
        {
            Id = id, Kind = "claude", KindName = "Claude", Origin = origin, Folder = folder, Label = label,
            Email = label.ToLowerInvariant().Replace(' ', '-') + "@example.com",
            Snapshot = new ProviderSnapshot
            {
                Account = new AccountInfo(label, plan),
                Windows =
                [
                    new() { Id = "session", Name = "Session", ScopeNote = "5 h", Percent = session, ResetsAt = now.AddSeconds(2.2 * hour), WindowLength = 5 * hour },
                    new() { Id = "week", Name = "Woche", ScopeNote = "7 d, alle Modelle", Percent = week, ResetsAt = now.AddSeconds(2.6 * 24 * hour), WindowLength = 7 * 24 * hour },
                ],
                FetchedAt = now.AddSeconds(-60),
            },
        };
    }
}
