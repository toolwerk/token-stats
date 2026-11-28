using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using TokenStats.Model;

namespace TokenStats.Providers;

/// <summary>
/// Claude Code: OAuth-Token aus <c>%USERPROFILE%\.claude\.credentials.json</c>
/// → <c>api.anthropic.com/api/oauth/usage</c>.
///
/// Unter Windows gibt es keinen Schlüsselbund-Eintrag; Claude Code schreibt die Zugangsdaten
/// in diese Datei. Weitere Konten über <c>CLAUDE_CONFIG_DIR</c>: <c>&lt;ordner&gt;\.credentials.json</c>. Das Token wird nur gelesen und nie erneuert: Ein Refresh rotiert das
/// Refresh-Token, und ohne Zurückschreiben wäre Claude Code danach abgemeldet.
/// Läuft es ab, erneuert Claude Code es beim nächsten Start selbst.
/// </summary>
public sealed partial class ClaudeProvider : IUsageProvider
{
    public string Kind => "claude";
    public string DisplayName => "Claude";
    public AccountSource Source { get; }

    static readonly Uri UsageUrl = new("https://api.anthropic.com/api/oauth/usage");
    const string Hint = "»claude« im Terminal einmal starten.";

    static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary><paramref name="configDirectory"/> = <c>CLAUDE_CONFIG_DIR</c> eines weiteren Kontos; <c>null</c> = Standardkonto.</summary>
    public ClaudeProvider(string? configDirectory = null, AccountOrigin origin = AccountOrigin.Detected)
    {
        var folder = configDirectory is null ? null : Path.GetFullPath(configDirectory).TrimEnd(Path.DirectorySeparatorChar);
        var account = ReadAccount(GlobalConfig(folder));
        Source = new AccountSource
        {
            Folder = folder, Origin = folder is null ? AccountOrigin.Standard : origin,
            Identity = account?.Uuid, Email = account?.Email, Name = account?.Name,
        };
    }

    public string Id => Source.Folder is { } folder ? $"{Kind}@{FolderHash.Of(folder)}" : Kind;

    string ConfigDirectory => Source.Folder ?? Path.Combine(Home, ".claude");
    string CredentialsFile => Path.Combine(ConfigDirectory, ".credentials.json");
    /// <summary>Logs dieses Kontos, für die Verbrauchsseite.</summary>
    public string ProjectsDirectory => Path.Combine(ConfigDirectory, "projects");

    /// <summary><c>~\.claude.json</c> beim Standardkonto, sonst <c>&lt;ordner&gt;\.claude.json</c>.</summary>
    static string GlobalConfig(string? folder) => folder is null ? Path.Combine(Home, ".claude.json") : Path.Combine(folder, ".claude.json");

    /// <summary>Beim zweiten Konto nennt der Hinweis den Ordner – ein schlichtes <c>claude</c> erneuert nur das Standardkonto.</summary>
    string RefreshHint => Source.Folder is { } folder
        ? $"»$env:CLAUDE_CONFIG_DIR=\"{folder}\"; claude« im Terminal einmal starten."
        : Hint;

    public bool IsInstalled() => Directory.Exists(ConfigDirectory);

    public async Task<ProviderSnapshot> FetchAsync()
    {
        var credentials = LoadCredentials() ?? throw ProviderException.NotLoggedIn(RefreshHint);
        if (credentials.ExpiresAt is { } expiresAt && expiresAt < DateTimeOffset.UtcNow)
            throw ProviderException.TokenExpired(RefreshHint);

        var data = await Http.GetJsonAsync(UsageUrl, new Dictionary<string, string>
        {
            ["Authorization"] = $"Bearer {credentials.AccessToken}",
            ["anthropic-beta"] = "oauth-2025-04-20",
        }, RefreshHint);
        var snapshot = Parse(data, DateTimeOffset.UtcNow);
        var account = ReadAccount(GlobalConfig(Source.Folder));
        snapshot.Account = new AccountInfo(account?.Name ?? account?.Email, credentials.Plan);
        return snapshot;
    }

    // Zugangsdaten

    public sealed record Credentials(string AccessToken, DateTimeOffset? ExpiresAt, string? Plan);

    Credentials? LoadCredentials()
    {
        try { return ParseCredentials(File.ReadAllBytes(CredentialsFile)); }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    public static Credentials? ParseCredentials(byte[] data)
    {
        var oauth = JsonRead.ParseObject(data).Obj("claudeAiOauth");
        var token = oauth.Str("accessToken");
        if (string.IsNullOrEmpty(token)) return null;
        var expiresAt = oauth.Num("expiresAt") is { } ms ? DateTimeOffset.FromUnixTimeMilliseconds((long)ms) : (DateTimeOffset?)null;
        return new Credentials(token, expiresAt, PlanName(oauth.Str("subscriptionType"), oauth.Str("rateLimitTier")));
    }

    /// <summary>"max" + "default_claude_max_20x" → "Max 20×"</summary>
    public static string? PlanName(string? subscription, string? tier)
    {
        if (string.IsNullOrEmpty(subscription)) return null;
        var name = char.ToUpperInvariant(subscription[0]) + subscription[1..];
        if (tier is not null && TierPattern().Match(tier) is { Success: true } match)
            name += $" {match.Groups[1].Value}×";
        return name;
    }

    [GeneratedRegex(@"_(\d+)x$")]
    private static partial Regex TierPattern();

    public sealed record Account(string? Uuid, string? Email, string? Name);

    /// <summary>Kontodaten aus <c>.claude.json</c> (keine Zugangsdaten).</summary>
    static Account? ReadAccount(string file)
    {
        try { return ParseAccount(File.ReadAllBytes(file)); }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    public static Account? ParseAccount(byte[] data)
    {
        var account = JsonRead.ParseObject(data).Obj("oauthAccount");
        if (account is null) return null;
        static string? NonEmpty(string? text) => string.IsNullOrEmpty(text) ? null : text;
        return new Account(NonEmpty(account.Str("accountUuid")), NonEmpty(account.Str("emailAddress")), NonEmpty(account.Str("displayName")));
    }

    // Antwort

    public static ProviderSnapshot Parse(byte[] data, DateTimeOffset now)
    {
        var response = JsonRead.ParseObject(data);

        const double week = 7 * 24 * 3600;
        static LimitWindow? Window(string id, string name, string note, JsonObject? source, double length)
        {
            if (source.Num("utilization") is not { } utilization) return null;
            return new LimitWindow
            {
                Id = id, Name = name, ScopeNote = note,
                Percent = utilization / 100,
                ResetsAt = JsonRead.Date(source.Str("resets_at")),
                WindowLength = length,
            };
        }

        // Seit 04.11.2026 fehlt `five_hour` (null): dann entfällt die Zeile „Session“.
        var windows = new[]
        {
            Window("session", "Session", "5 h", response.Obj("five_hour"), 5 * 3600),
            Window("week", "Woche", "7 d, alle Modelle", response.Obj("seven_day"), week),
            Window("opus", "Opus", "Wochenlimit", response.Obj("seven_day_opus"), week),
            Window("sonnet", "Sonnet", "Wochenlimit", response.Obj("seven_day_sonnet"), week),
        }.OfType<LimitWindow>().ToList();

        // Fehlt `seven_day`, kommt die Woche aus `limits` (`weekly_all`).
        if (windows.All(w => w.Id != "week"))
        {
            foreach (var limit in response.Arr("limits") ?? [])
            {
                if (limit.Str("kind") != "weekly_all" || limit.Num("percent") is not { } percent) continue;
                var index = windows.Count > 0 && windows[0].Id == "session" ? 1 : 0;
                windows.Insert(index, new LimitWindow
                {
                    Id = "week", Name = "Woche", ScopeNote = "7 d, alle Modelle",
                    Percent = percent / 100, ResetsAt = JsonRead.Date(limit.Str("resets_at")), WindowLength = week,
                });
                break;
            }
        }

        // Neuere Antworten führen Modell-Limits zusätzlich in `limits`.
        foreach (var limit in response.Arr("limits") ?? [])
        {
            if (limit.Str("kind") != "weekly_scoped") continue;
            var name = limit.Obj("scope").Obj("model").Str("display_name");
            if (string.IsNullOrEmpty(name) || limit.Num("percent") is not { } percent
                || windows.Any(w => string.Equals(w.Name, name, StringComparison.OrdinalIgnoreCase)))
                continue;
            windows.Add(new LimitWindow
            {
                Id = $"model-{name.ToLowerInvariant()}", Name = name, ScopeNote = "Wochenlimit",
                Percent = percent / 100, ResetsAt = JsonRead.Date(limit.Str("resets_at")), WindowLength = week,
            });
        }

        // Kein einziges Limit: Form unbekannt, nicht leer anzeigen.
        if (windows.Count == 0) throw ProviderException.BadResponse();

        var extras = new List<ExtraValue>();
        var extra = response.Obj("extra_usage");
        if (extra.Bool("is_enabled") == true && extra.Num("monthly_limit") is { } monthly and > 0)
        {
            var used = extra.Num("used_credits") ?? 0;
            var currency = extra.Str("currency");
            int? decimals = extra.Num("decimal_places") is { } places ? (int)places : null;
            extras.Add(new ExtraValue("extra", $"Extra {Format.Amount(used, currency, decimals)} / {Format.Amount(monthly, currency, decimals)}"));
        }

        return new ProviderSnapshot { Windows = windows, Extras = extras, FetchedAt = now };
    }
}
