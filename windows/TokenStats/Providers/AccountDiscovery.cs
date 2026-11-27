namespace TokenStats.Providers;

/// <summary>
/// Findet die Konten aller Anbieter (SPEC §6 „Mehrere Konten je Anbieter“): das Standardkonto,
/// Ordner wie <c>%USERPROFILE%\.claude-2</c> direkt im Profil und von Hand hinzugefügte Ordner.
/// Liest nur Ordnerlisten und Kontodateien, keine Tokens.
/// </summary>
public sealed class AccountDiscovery(string? home = null, IReadOnlyDictionary<string, List<string>>? manualFolders = null)
{
    /// <summary>Anbieter, deren Konten in eigenen Ordnern liegen können.</summary>
    public sealed record FolderKind(string Id, string DisplayName, string StandardFolder, string Marker, string Variable)
    {
        public static readonly FolderKind Claude = new("claude", "Claude", ".claude", ".claude.json", "CLAUDE_CONFIG_DIR");
        public static readonly FolderKind Codex = new("codex", "Codex", ".codex", "auth.json", "CODEX_HOME");
        public static readonly FolderKind[] All = [Claude, Codex];

        /// <summary>
        /// Anmeldebefehl für PowerShell, im Stil der übrigen Windows-Hinweise:
        /// <c>$env:CLAUDE_CONFIG_DIR="C:\…"; claude</c> bzw. <c>$env:CODEX_HOME="C:\…"; codex login</c>.
        /// </summary>
        public string LoginCommand(string folder) =>
            $"$env:{Variable}=\"{folder}\"; " + (this == Claude ? "claude" : "codex login");

        /// <summary>„Keine Anmeldung in diesem Ordner. Im Terminal »…« starten.“</summary>
        public string NotSignedInHint(string folder) =>
            $"Keine Anmeldung in diesem Ordner. Im Terminal »{LoginCommand(folder)}« starten.";
    }

    readonly string home = home ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>Alle Einträge: Claude und Codex je Standard, automatisch, von Hand; dazu Antigravity und Ollama.</summary>
    public List<AccountEntry> Entries()
    {
        var result = new List<AccountEntry>();
        foreach (var kind in FolderKind.All) result.AddRange(Accounts(kind));
        result.Add(new AccountEntry(new AntigravityProvider()));
        result.Add(new AccountEntry(new OllamaProvider()));
        return result;
    }

    /// <summary>Nur die Konten, die abgefragt werden können.</summary>
    public List<IUsageProvider> Providers() => Entries().Where(entry => entry.CanFetch).Select(entry => entry.Provider).ToList();

    /// <summary>
    /// Einträge eines Anbieters in der Reihenfolge Standard, automatisch gefunden, von Hand. Nichts
    /// wird stumm verworfen: Ein Ordner „von Hand“ bleibt auch fehlend, ohne Anmeldung oder doppelt
    /// in der Liste, damit er sich in den Einstellungen entfernen lässt.
    /// </summary>
    public List<AccountEntry> Accounts(FolderKind kind)
    {
        var entries = new List<AccountEntry>();
        // Echter Pfad bzw. Anmeldung → Konto-ID des ersten Eintrags damit.
        var paths = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var identities = new Dictionary<string, string>();

        var standard = Make(kind, null, AccountOrigin.Standard);
        entries.Add(new AccountEntry(standard));
        paths[Normalize(Path.Combine(home, kind.StandardFolder))] = standard.Id;
        // Ein Standardkonto ohne Ordner ist unsichtbar; dagegen zählt keine Anmeldung als doppelt.
        if (standard.IsInstalled() && standard.Source.Identity is { } standardIdentity) identities[standardIdentity] = standard.Id;

        // Derselbe Ordner zweimal in den Einstellungen ist derselbe Eintrag, kein Doppel.
        // Ungültige Einträge (leer, unzulässige Zeichen) aus settings.json überspringen, sonst
        // wirft Path.GetFullPath schon beim Start.
        var manual = (manualFolders?.GetValueOrDefault(kind.Id) ?? [])
            .Where(IsValidPath)
            .DistinctBy(folder => Path.GetFullPath(folder).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                        StringComparer.OrdinalIgnoreCase);
        var candidates = DetectedFolders(kind).Select(folder => (Folder: folder, Origin: AccountOrigin.Detected))
            .Concat(manual.Select(folder => (Folder: folder, Origin: AccountOrigin.Manual)));

        foreach (var (folder, origin) in candidates)
        {
            var provider = Make(kind, folder, origin);
            if (origin == AccountOrigin.Manual && !Directory.Exists(folder))
            {
                entries.Add(new AccountEntry(provider, AccountStatus.MissingFolder));
                continue;
            }

            // Gleicher Ordner (auch per Junction/Symlink) oder gleiche Anmeldung: sonst zählten
            // beide Abfragen gegen dasselbe Rate-Limit, und die Zahlen stünden doppelt da.
            var path = Normalize(folder);
            if (paths.TryGetValue(path, out var samePath))
            {
                entries.Add(new AccountEntry(provider, AccountStatus.Duplicate, samePath));
                continue;
            }
            if (provider.Source.Identity is { } identity && identities.TryGetValue(identity, out var sameLogin))
            {
                entries.Add(new AccountEntry(provider, AccountStatus.Duplicate, sameLogin));
                continue;
            }

            paths[path] = provider.Id;
            if (provider.Source.Identity is { } newIdentity) identities[newIdentity] = provider.Id;
            var signedIn = kind == FolderKind.Claude ? provider.Source.HasAccount : File.Exists(Path.Combine(folder, kind.Marker));
            entries.Add(new AccountEntry(provider, origin == AccountOrigin.Manual && !signedIn ? AccountStatus.NotSignedIn : AccountStatus.Ok));
        }
        return entries;
    }

    /// <summary><c>.claude-*</c> bzw. <c>.codex-*</c> (auch mit <c>_</c>), sofern die Kontodatei darin liegt.</summary>
    public IEnumerable<string> DetectedFolders(FolderKind kind)
    {
        if (!Directory.Exists(home)) return [];
        return Directory.EnumerateDirectories(home)
            .Where(path =>
            {
                var name = Path.GetFileName(path);
                return name.StartsWith(kind.StandardFolder + "-", StringComparison.OrdinalIgnoreCase)
                    || name.StartsWith(kind.StandardFolder + "_", StringComparison.OrdinalIgnoreCase);
            })
            .Where(path => File.Exists(Path.Combine(path, kind.Marker)))
            .Order(StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>Echter Pfad, damit ein Junction/Symlink auf denselben Ordner nur einmal zählt.</summary>
    static string Normalize(string path)
    {
        var full = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        try
        {
            if (new DirectoryInfo(full).ResolveLinkTarget(returnFinalTarget: true) is { } target)
                return Path.GetFullPath(target.FullName).TrimEnd(Path.DirectorySeparatorChar);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        return full;
    }

    static bool IsValidPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return false;
        try
        {
            Path.GetFullPath(path);
            return true;
        }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }

    static IUsageProvider Make(FolderKind kind, string? folder, AccountOrigin origin) =>
        kind.Id == "claude" ? new ClaudeProvider(folder, origin) : new CodexProvider(folder, origin);
}
