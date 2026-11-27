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
    }

    readonly string home = home ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>Alle Konten, Standard vor automatisch vor von Hand, doppelte Anmeldungen nur einmal.</summary>
    public List<IUsageProvider> Providers()
    {
        var result = new List<IUsageProvider>();
        foreach (var kind in FolderKind.All) result.AddRange(Accounts(kind));
        result.Add(new AntigravityProvider());
        result.Add(new OllamaProvider());
        return result;
    }

    public List<IUsageProvider> Accounts(FolderKind kind)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { Normalize(Path.Combine(home, kind.StandardFolder)) };
        var folders = new List<(string Path, AccountOrigin Origin)>();
        var manual = manualFolders?.GetValueOrDefault(kind.Id) ?? [];
        foreach (var (folder, origin) in DetectedFolders(kind).Select(f => (f, AccountOrigin.Detected))
                     .Concat(manual.Select(f => (f, AccountOrigin.Manual))))
        {
            if (seen.Add(Normalize(folder))) folders.Add((folder, origin));
        }

        var providers = new List<IUsageProvider> { Make(kind, null, AccountOrigin.Standard) };
        providers.AddRange(folders.Select(f => Make(kind, f.Path, f.Origin)));

        // Zwei Ordner mit derselben Anmeldung: nur der erste zählt, sonst doppelte Abfragen.
        var identities = new HashSet<string>();
        return providers.Where(p => p.Source.Identity is not { } identity || identities.Add(identity)).ToList();
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
        catch (IOException) { }
        return full;
    }

    static IUsageProvider Make(FolderKind kind, string? folder, AccountOrigin origin) =>
        kind.Id == "claude" ? new ClaudeProvider(folder, origin) : new CodexProvider(folder, origin);
}
