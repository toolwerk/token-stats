namespace TokenStats.Tests;

// Demo-Konten für Screenshots (SPEC §6): erfunden, ohne Erkennung, mit denselben Zuständen wie echte Konten.

public sealed class DemoAccountTests
{
    static readonly DateTimeOffset Now = new(2026, 11, 27, 10, 0, 0, TimeSpan.FromHours(1));

    static (AppSettings Settings, UsageStore Store) Show(DemoAccounts.Scenario scenario, string? hidden = null)
    {
        var settings = new AppSettings();
        var store = new UsageStore([], settings, cachePath: null);
        var accounts = DemoAccounts.Accounts(scenario, Now, new Dictionary<string, ProviderSnapshot>())
            .Select(account => account.Id == hidden ? account with { Hidden = true } : account).ToList();
        DemoAccounts.Show(store, settings, accounts);
        return (settings, store);
    }

    [Fact]
    public void MultiShowsThreeClaudeAccountsAndPicksTheTightest()
    {
        var (_, store) = Show(DemoAccounts.Scenario.Multi);
        Assert.Equal(["Privat", "Arbeit", "Kunde A"], store.AccountsOfKind("claude").Select(p => store.Label(p)));
        Assert.Equal("Claude · Kunde A", store.Title(store.AccountsOfKind("claude")[2]));
        // Ohne Vorauswahl ist das knappste Konto gewählt: Kunde A mit 100 % in der Woche.
        Assert.Equal(DemoAccounts.KundeA, store.Tightest?.ProviderId);
        Assert.All(store.Entries, entry => Assert.IsType<DemoAccountProvider>(entry.Provider));
    }

    [Fact]
    public void InvalidShowsMissingFolderUntilHidden()
    {
        var (_, store) = Show(DemoAccounts.Scenario.Invalid);
        var missing = Assert.Single(store.Entries, entry => entry.Id == DemoAccounts.KundeA);
        Assert.Equal(AccountStatus.MissingFolder, missing.Status);
        Assert.True(missing.NeedsSetup);
        Assert.Contains(store.VisibleEntries, entry => entry.Id == DemoAccounts.KundeA);
        Assert.DoesNotContain(store.PolledProviders, provider => provider.Id == DemoAccounts.KundeA);
        // Doppelte Anmeldung nie im Popup, Ordner ohne Anmeldung schon (grau mit „!“).
        Assert.DoesNotContain(store.VisibleEntries, entry => entry.Status == AccountStatus.Duplicate);
        Assert.Contains(store.VisibleEntries, entry => entry.Status == AccountStatus.NotSignedIn && entry.NeedsSetup);

        var (settings, hiddenStore) = Show(DemoAccounts.Scenario.Invalid, hidden: DemoAccounts.KundeA);
        Assert.True(settings.IsHidden(DemoAccounts.KundeA));
        Assert.DoesNotContain(hiddenStore.VisibleEntries, entry => entry.Id == DemoAccounts.KundeA);
        Assert.Contains(hiddenStore.Entries, entry => entry.Id == DemoAccounts.KundeA && entry.IsListed);
    }

    [Fact]
    public void ErrorsCarryTheProviderTexts()
    {
        var (_, store) = Show(DemoAccounts.Scenario.Errors);
        Assert.Equal("Server antwortet mit HTTP 503.", store.State(DemoAccounts.KundeA).Error);
        Assert.Null(store.State(DemoAccounts.KundeA).Snapshot);
        Assert.StartsWith("Nicht angemeldet. »$env:CLAUDE_CONFIG_DIR=", store.State(DemoAccounts.Arbeit).Error);
    }

    [Fact]
    public void NoRealNamesAddressesOrFolders()
    {
        foreach (var scenario in Enum.GetValues<DemoAccounts.Scenario>())
            foreach (var account in DemoAccounts.Accounts(scenario, Now, new Dictionary<string, ProviderSnapshot>()))
            {
                if (account.Email is { } email) Assert.EndsWith("@example.com", email);
                var entry = account.Entry();
                // Im Profil nur als %USERPROFILE%\…, sonst außerhalb (D:\…) – nie der echte Benutzername.
                if (entry.Source.FolderDisplay is { } folder)
                    Assert.True(folder.StartsWith("%USERPROFILE%", StringComparison.Ordinal) || folder.StartsWith(@"D:\", StringComparison.Ordinal), folder);
                // Der volle Pfad landet in Hinweisen („Keine Anmeldung …“) – dort nie das Profil.
                if (account.Status == AccountStatus.NotSignedIn) Assert.StartsWith(@"D:\", account.Folder);
                if (account.Error is { } error)
                    Assert.DoesNotContain(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), error, StringComparison.OrdinalIgnoreCase);
            }
    }

    [Fact]
    public void StandardDemoListsAllFourProvidersWithoutAccountFiles()
    {
        var store = new UsageStore([], new AppSettings(), cachePath: null);
        store.ShowDemo(new Dictionary<string, ProviderSnapshot>());
        Assert.Equal(["Antigravity", "Claude", "Codex", "Ollama"], store.SortedProviders.Select(p => p.DisplayName));
        Assert.All(store.SortedProviders, provider => Assert.Null(provider.Source.Email));
    }
}
