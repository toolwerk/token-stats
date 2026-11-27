using TokenStats.Model;

namespace TokenStats.Providers;

/// <summary>
/// Ein Anbieter = eine Datei, die dieses Interface erfüllt (SPEC §7). Jede Instanz steht für ein
/// Konto; ein Anbieter kann mehrere haben (SPEC §6 „Mehrere Konten je Anbieter“).
/// </summary>
public interface IUsageProvider
{
    /// <summary>Konto-ID: beim Standardkonto die Anbieter-ID (<c>claude</c>), sonst <c>claude@&lt;hash&gt;</c>.</summary>
    string Id { get; }
    /// <summary>Anbieter-ID, für alle Konten eines Anbieters gleich.</summary>
    string Kind => Id;
    /// <summary>Name des Anbieters, ohne Konto.</summary>
    string DisplayName { get; }
    /// <summary>Herkunft des Kontos, für Bezeichnung und Einstellungen.</summary>
    AccountSource Source => new();
    bool IsDefaultAccount => Id == Kind;
    /// <summary>Credential-Quelle vorhanden?</summary>
    bool IsInstalled();
    Task<ProviderSnapshot> FetchAsync();
}

public enum AccountOrigin { Standard, Detected, Manual }

/// <summary>Woher die automatische Bezeichnung stammt – für den Hinweis beim Umbenennen.</summary>
public enum LabelOrigin { Email, Name, Folder }

public static class LabelOrigins
{
    /// <summary>„aus der E-Mail“ usw., für „Leer lassen für „frank“ (aus der E-Mail).“</summary>
    public static string Description(this LabelOrigin origin) => origin switch
    {
        LabelOrigin.Email => "aus der E-Mail",
        LabelOrigin.Name => "aus dem Kontonamen",
        _ => "aus dem Ordnernamen",
    };
}

/// <summary>Automatische Bezeichnung samt Herkunft; <see cref="Origin"/> fehlt beim Notbehelf „Standard“.</summary>
public sealed record AutoLabel(string Text, LabelOrigin? Origin);

/// <summary>Woher ein Konto kommt – nur Ordner und Kontodaten, keine Zugangsdaten.</summary>
public sealed record AccountSource
{
    /// <summary>Konfigurationsordner (<c>~\.claude-2</c>); <c>null</c> beim Standardkonto und bei fester Quelle.</summary>
    public string? Folder { get; init; }
    public AccountOrigin Origin { get; init; } = AccountOrigin.Standard;
    /// <summary>Kontokennung des Anbieters (<c>accountUuid</c>, ChatGPT-<c>account_id</c>) – erkennt doppelte Anmeldungen.</summary>
    public string? Identity { get; init; }
    public string? Email { get; init; }
    public string? Name { get; init; }

    /// <summary>Kontodaten gefunden (bei Claude: <c>oauthAccount</c> in <c>.claude.json</c>)?</summary>
    public bool HasAccount => Identity is not null || Email is not null || Name is not null;

    /// <summary>Anzeigeform eines Ordners: <c>%USERPROFILE%\.claude-2</c> statt des vollen Profilpfads.</summary>
    public static string Display(string folder)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile).TrimEnd(Path.DirectorySeparatorChar);
        if (string.Equals(folder, home, StringComparison.OrdinalIgnoreCase)) return "%USERPROFILE%";
        return folder.StartsWith(home + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
            ? "%USERPROFILE%" + folder[home.Length..]
            : folder;
    }

    /// <summary>Kurzform für Hinweise: <c>%USERPROFILE%\.claude-2</c>.</summary>
    public string? FolderDisplay => Folder is null ? null : Display(Folder);

    /// <summary>Automatische Bezeichnung: lokaler Teil der E-Mail, Anzeigename, Ordnername.</summary>
    public string? AutomaticLabel => AutomaticLabelInfo?.Text;

    /// <summary>Wie <see cref="AutomaticLabel"/>, dazu die Herkunft.</summary>
    public AutoLabel? AutomaticLabelInfo
    {
        get
        {
            if (Email?.Split('@')[0] is { Length: > 0 } local) return new AutoLabel(local, LabelOrigin.Email);
            if (!string.IsNullOrEmpty(Name)) return new AutoLabel(Name, LabelOrigin.Name);
            if (Folder is null) return null;
            var last = Path.GetFileName(Folder.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
            var text = last.StartsWith('.') ? last[1..] : last;
            return text.Length > 0 ? new AutoLabel(text, LabelOrigin.Folder) : null;
        }
    }
}

/// <summary>Zustand eines erkannten Kontos (SPEC §6 „Mehrere Konten je Anbieter“).</summary>
public enum AccountStatus
{
    Ok,
    /// <summary>Ordner „von Hand“, der nicht (mehr) existiert: sichtbar, nicht abgefragt, entfernbar.</summary>
    MissingFolder,
    /// <summary>Ordner „von Hand“ ohne Kontodatei. Claude wird trotzdem abgefragt, Codex ohne <c>auth.json</c> nicht.</summary>
    NotSignedIn,
    /// <summary>Gleicher Ordner oder gleiche Anmeldung wie <see cref="AccountEntry.DuplicateOf"/>: nie abgefragt, nie im Popup.</summary>
    Duplicate,
}

/// <summary>Ein Eintrag der Kontenliste: Konto plus Zustand.</summary>
public sealed record AccountEntry(IUsageProvider Provider, AccountStatus Status = AccountStatus.Ok, string? DuplicateOf = null)
{
    public string Id => Provider.Id;
    public string Kind => Provider.Kind;
    public AccountSource Source => Provider.Source;

    /// <summary>
    /// In Einstellungen und Popup aufgeführt? Einträge mit eigenem Zustand immer, sonst nur mit
    /// vorhandener Quelle – ein fehlendes Standardkonto erscheint wie bisher gar nicht.
    /// </summary>
    public bool IsListed => Status != AccountStatus.Ok || Provider.IsInstalled();

    /// <summary>Kann abgefragt werden: nicht fehlend, nicht doppelt, Quelle vorhanden (Codex ohne <c>auth.json</c> nicht).</summary>
    public bool CanFetch => (Status is AccountStatus.Ok or AccountStatus.NotSignedIn) && Provider.IsInstalled();
}

/// <summary>Stabile Kurzkennung eines Ordners: die ersten 8 Hex-Zeichen von SHA-256(Pfad) – wie auf dem Mac.</summary>
public static class FolderHash
{
    public static string Of(string path) =>
        Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(path)))[..8];
}

public enum ProviderErrorKind
{
    NotLoggedIn,
    /// <summary>Ablaufzeit laut Zugangsdaten vorbei – ohne Anfrage erkannt.</summary>
    TokenExpired,
    /// <summary>Server hat das Token abgewiesen (HTTP 401/403).</summary>
    Unauthorized,
    /// <summary>
    /// Token abgelaufen, aber kein Fehler: Erneuert wird es erst bei der nächsten Nutzung der
    /// CLI, bis dahin gilt der letzte Stand (Antigravity).
    /// </summary>
    WaitingForToken,
    RateLimited,
    Http,
    BadResponse,
    Network,
}

public sealed class ProviderException(ProviderErrorKind kind, string? detail = null, TimeSpan? retryAfter = null, int status = 0)
    : Exception(Describe(kind, detail, status))
{
    public ProviderErrorKind Kind { get; } = kind;
    public TimeSpan? RetryAfter { get; } = retryAfter;

    /// <summary>
    /// Fehler aus der lokalen Prüfung der Zugangsdaten: Es ging keine Anfrage raus,
    /// also zählt der Versuch nicht gegen das Abfrageintervall.
    /// </summary>
    public bool IsLocal => Kind is ProviderErrorKind.NotLoggedIn or ProviderErrorKind.TokenExpired or ProviderErrorKind.WaitingForToken;

    public static ProviderException NotLoggedIn(string hint) => new(ProviderErrorKind.NotLoggedIn, hint);
    public static ProviderException TokenExpired(string hint) => new(ProviderErrorKind.TokenExpired, hint);
    public static ProviderException Unauthorized(string hint) => new(ProviderErrorKind.Unauthorized, hint);
    public static ProviderException WaitingForToken(string hint) => new(ProviderErrorKind.WaitingForToken, hint);
    public static ProviderException RateLimited(TimeSpan? retryAfter) => new(ProviderErrorKind.RateLimited, retryAfter: retryAfter);
    public static ProviderException Http(int status) => new(ProviderErrorKind.Http, status: status);
    public static ProviderException BadResponse() => new(ProviderErrorKind.BadResponse);
    public static ProviderException Network(string text) => new(ProviderErrorKind.Network, text);

    static string Describe(ProviderErrorKind kind, string? detail, int status) => kind switch
    {
        ProviderErrorKind.NotLoggedIn => $"Nicht angemeldet. {detail}",
        ProviderErrorKind.TokenExpired or ProviderErrorKind.Unauthorized => $"Anmeldung abgelaufen. {detail}",
        ProviderErrorKind.WaitingForToken => detail ?? "",
        ProviderErrorKind.RateLimited => "Abfragelimit erreicht.",
        ProviderErrorKind.Http => $"Server antwortet mit HTTP {status}.",
        ProviderErrorKind.BadResponse => "Unerwartete Antwort vom Server.",
        _ => $"Keine Verbindung: {detail}",
    };
}
