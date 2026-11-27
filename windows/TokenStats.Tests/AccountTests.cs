using System.Text;

namespace TokenStats.Tests;

// Mehrere Konten je Anbieter (SPEC §6): Kennungen, Erkennung, Bezeichnung, Verbrauch über alle Konten.

public sealed class AccountTests : IDisposable
{
    readonly string home = Directory.CreateTempSubdirectory("tokenstats-accounts-").FullName;

    public void Dispose()
    {
        Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
        Directory.Delete(home, recursive: true);
    }

    string ClaudeFolder(string name, string uuid, string email)
    {
        var folder = Directory.CreateDirectory(Path.Combine(home, name)).FullName;
        File.WriteAllText(Path.Combine(folder, ".claude.json"),
            $$$"""{"oauthAccount":{"accountUuid":"{{{uuid}}}","emailAddress":"{{{email}}}","displayName":"Privat"}}""");
        return folder;
    }

    [Fact]
    public void FolderHashMatchesMac()
    {
        // Dieselbe Rechnung wie auf dem Mac: erste 8 Hex-Zeichen von SHA-256(Pfad).
        Assert.Equal("03abf0ee", FolderHash.Of("/Users/test/.claude-work"));
        Assert.Equal("9f11aad2", FolderHash.Of(@"C:\Users\test\.claude-work"));
        Assert.Equal("claude", new ClaudeProvider().Id);
        Assert.Equal("codex", new CodexProvider().Id);
        Assert.Equal($"claude@{FolderHash.Of(@"C:\Users\test\.claude-work")}", new ClaudeProvider(@"C:\Users\test\.claude-work").Id);
    }

    [Fact]
    public void ReadsAccountData()
    {
        var account = ClaudeProvider.ParseAccount(Encoding.UTF8.GetBytes("""{"oauthAccount":{"accountUuid":"u-1","emailAddress":"frank@example.com","displayName":""}}"""));
        Assert.Equal(new ClaudeProvider.Account("u-1", "frank@example.com", null), account);
        Assert.Null(ClaudeProvider.ParseAccount(Encoding.UTF8.GetBytes("{}")));
    }

    [Fact]
    public void DetectsFoldersInProfile()
    {
        ClaudeFolder(".claude-2", "u-2", "second@example.com");
        ClaudeFolder(".claude_work", "u-3", "work@example.com");
        Directory.CreateDirectory(Path.Combine(home, ".claude-empty"));   // ohne Kontodatei kein Konto
        Directory.CreateDirectory(Path.Combine(home, ".claudeX"));

        var found = new AccountDiscovery(home).Accounts(AccountDiscovery.FolderKind.Claude);
        Assert.Equal(3, found.Count);
        Assert.True(found[0].Provider.IsDefaultAccount);
        Assert.Equal(["second@example.com", "work@example.com"], found.Skip(1).Select(p => p.Source.Email).Order());
        Assert.All(found.Skip(1), p => Assert.Equal(AccountOrigin.Detected, p.Source.Origin));
        Assert.All(found.Skip(1), p => Assert.Equal(AccountStatus.Ok, p.Status));
    }

    [Fact]
    public void MarksDuplicateLoginsInsteadOfDroppingThem()
    {
        ClaudeFolder(".claude-2", "u-2", "privat@example.com");
        var copy = ClaudeFolder(Path.Combine("elsewhere", "claude-copy"), "u-2", "privat@example.com");
        var manual = ClaudeFolder(Path.Combine("elsewhere", "claude-kunde"), "u-9", "kunde-a@example.com");

        // Derselbe Ordner zweimal in den Einstellungen ist ein Eintrag, kein Doppel.
        var folders = new Dictionary<string, List<string>> { ["claude"] = [copy, manual, manual] };
        var found = new AccountDiscovery(home, folders).Accounts(AccountDiscovery.FolderKind.Claude).Skip(1).ToList();
        Assert.Equal(["privat@example.com", "privat@example.com", "kunde-a@example.com"], found.Select(p => p.Source.Email));
        Assert.Equal([AccountStatus.Ok, AccountStatus.Duplicate, AccountStatus.Ok], found.Select(p => p.Status));
        Assert.Equal(found[0].Id, found[1].DuplicateOf);
        Assert.False(found[1].CanFetch);
        Assert.Equal(AccountOrigin.Manual, found[^1].Source.Origin);
    }

    [Fact]
    public void SameFolderTwiceIsDuplicateOfFirst()
    {
        var detected = ClaudeFolder(".claude-arbeit", "u-4", "arbeit@example.com");
        // Von Hand derselbe Ordner wie der automatisch gefundene, einmal mit „\“ am Ende.
        var folders = new Dictionary<string, List<string>> { ["claude"] = [detected + Path.DirectorySeparatorChar] };
        var found = new AccountDiscovery(home, folders).Accounts(AccountDiscovery.FolderKind.Claude).Skip(1).ToList();

        Assert.Equal(2, found.Count);
        Assert.Equal(AccountStatus.Ok, found[0].Status);
        Assert.Equal(AccountOrigin.Detected, found[0].Source.Origin);
        Assert.Equal(AccountStatus.Duplicate, found[1].Status);
        Assert.Equal(AccountOrigin.Manual, found[1].Source.Origin);
        Assert.Equal(found[0].Id, found[1].DuplicateOf);
    }

    [Fact]
    public void MissingManualFolderStaysListed()
    {
        var gone = Path.Combine(home, "laufwerk", "claude-kunde");
        var folders = new Dictionary<string, List<string>> { ["claude"] = [gone] };
        var discovery = new AccountDiscovery(home, folders);
        var entry = Assert.Single(discovery.Accounts(AccountDiscovery.FolderKind.Claude), e => e.Source.Origin == AccountOrigin.Manual);

        Assert.Equal(AccountStatus.MissingFolder, entry.Status);
        Assert.True(entry.IsListed);
        Assert.False(entry.CanFetch);
        // Einrichtungsfehler: Popup bietet „Einstellungen öffnen“; der Haken bleibt leer, auch wenn nicht ausgeblendet.
        Assert.True(entry.NeedsSetup);
        Assert.False(entry.ShowsAsChecked(hidden: false));
        Assert.False(entry.ShowsAsChecked(hidden: true));

        // Im Popup sichtbar (grau mit „!“), aber nicht abgefragt und nicht im Verbrauch.
        var store = new UsageStore([], new AppSettings(), cachePath: null, () => discovery.Accounts(AccountDiscovery.FolderKind.Claude));
        Assert.Contains(store.VisibleEntries, e => e.Id == entry.Id);
        Assert.DoesNotContain(store.PolledProviders, p => p.Id == entry.Id);
        Assert.DoesNotContain(Path.Combine(gone, "projects"), store.LogRoots.Claude);

        // Ist das Laufwerk wieder da, ist es ein normales Konto.
        ClaudeFolder(Path.Combine("laufwerk", "claude-kunde"), "u-5", "kunde-a@example.com");
        store.ReloadAccounts();
        var back = store.Entries.Single(e => e.Id == entry.Id);
        Assert.Equal(AccountStatus.Ok, back.Status);
        Assert.Contains(store.PolledProviders, p => p.Id == entry.Id);
        Assert.False(back.NeedsSetup);
        Assert.True(back.ShowsAsChecked(hidden: false));
        Assert.False(back.ShowsAsChecked(hidden: true));
    }

    [Fact]
    public void ManualFoldersWithoutLoginAreNotSignedIn()
    {
        var codex = Directory.CreateDirectory(Path.Combine(home, "elsewhere", "codex-arbeit")).FullName;
        var claude = Directory.CreateDirectory(Path.Combine(home, "elsewhere", "claude-arbeit")).FullName;
        var folders = new Dictionary<string, List<string>> { ["codex"] = [codex], ["claude"] = [claude] };
        var discovery = new AccountDiscovery(home, folders);

        var codexEntry = Assert.Single(discovery.Accounts(AccountDiscovery.FolderKind.Codex), e => e.Source.Origin == AccountOrigin.Manual);
        Assert.Equal(AccountStatus.NotSignedIn, codexEntry.Status);
        Assert.True(codexEntry.IsListed);
        Assert.False(codexEntry.CanFetch);   // ohne auth.json keine Abfrage
        Assert.True(codexEntry.NeedsSetup);
        Assert.True(codexEntry.ShowsAsChecked(hidden: false));

        // Claude ohne .claude.json wird trotzdem abgefragt: Die Anmeldung kann woanders liegen.
        var claudeEntry = Assert.Single(discovery.Accounts(AccountDiscovery.FolderKind.Claude), e => e.Source.Origin == AccountOrigin.Manual);
        Assert.Equal(AccountStatus.NotSignedIn, claudeEntry.Status);
        Assert.True(claudeEntry.CanFetch);
        // Wird abgefragt: Ein Fehler beim Abruf ist kein Einrichtungsfehler, also kein „Einstellungen öffnen“.
        Assert.False(claudeEntry.NeedsSetup);

        var store = new UsageStore([], new AppSettings(), cachePath: null,
            () => discovery.Accounts(AccountDiscovery.FolderKind.Codex).Concat(discovery.Accounts(AccountDiscovery.FolderKind.Claude)).ToList());
        Assert.Contains(store.VisibleEntries, e => e.Id == codexEntry.Id);
        Assert.DoesNotContain(store.PolledProviders, p => p.Id == codexEntry.Id);
        Assert.DoesNotContain(codex, store.LogRoots.Codex);
        Assert.Contains(store.PolledProviders, p => p.Id == claudeEntry.Id);
    }

    [Fact]
    public void NotSignedInHintUsesPowerShell()
    {
        Assert.Equal("Keine Anmeldung in diesem Ordner. Im Terminal »$env:CLAUDE_CONFIG_DIR=\"C:\\Daten\\claude-arbeit\"; claude« starten.",
                     AccountDiscovery.FolderKind.Claude.NotSignedInHint(@"C:\Daten\claude-arbeit"));
        Assert.Equal("Keine Anmeldung in diesem Ordner. Im Terminal »$env:CODEX_HOME=\"C:\\Daten\\codex-arbeit\"; codex login« starten.",
                     AccountDiscovery.FolderKind.Codex.NotSignedInHint(@"C:\Daten\codex-arbeit"));
    }

    [Fact]
    public void SplitsHintsIntoSentencesAndCommands()
    {
        static CommandText.Part P(string text) => new(text, IsCommand: false);
        static CommandText.Part C(string text) => new(text, IsCommand: true);

        Assert.Equal([P("Keine Anmeldung in diesem Ordner. Im Terminal"), C("$env:CODEX_HOME=\"C:\\Daten\\codex-arbeit\"; codex login"), P("starten.")],
                     CommandText.Split(AccountDiscovery.FolderKind.Codex.NotSignedInHint(@"C:\Daten\codex-arbeit")));
        // Satzzeichen direkt hinter dem Befehl fallen mit den »…« weg.
        Assert.Equal([P("Codex einmal starten oder"), C("codex login")], CommandText.Split("Codex einmal starten oder »codex login«."));
        Assert.Equal([P("Weitere Konten:"), C("claude"), P("bzw."), C("codex"), P("Ordner findet Token Stats selbst.")],
                     CommandText.Split("Weitere Konten: »claude« bzw. »codex«. Ordner findet Token Stats selbst."));
        // Teil eines Wortes bleibt im Satz.
        Assert.Equal([P("Stand der letzten »agy«-Sitzung. Aktualisiert sich, sobald"), C("agy"), P("läuft.")],
                     CommandText.Split("Stand der letzten »agy«-Sitzung. Aktualisiert sich, sobald »agy« läuft."));
        Assert.Equal([P("Abfragelimit erreicht.")], CommandText.Split("Abfragelimit erreicht."));
        Assert.Empty(CommandText.Split(""));
    }

    [Fact]
    public void WrapsCommandsWithoutCuttingThem()
    {
        var command = AccountDiscovery.FolderKind.Claude.LoginCommand(@"C:\Daten\claude-arbeit");   // 55 Zeichen, erster Teil 48

        // Passt alles, eine Zeile.
        Assert.Equal(new[] { command }, CommandText.Wrap(command, 60));
        // Leerzeichen geht vor; die Folgezeile ist um zwei Zeichen eingerückt.
        Assert.Equal(new[] { "$env:CLAUDE_CONFIG_DIR=\"C:\\Daten\\claude-arbeit\";", "  claude" }, CommandText.Wrap(command, 50));
        // Ein zu langer Teil bricht nach „/“, das Zeichen bleibt am Zeilenende; die Einrückung zählt mit.
        Assert.Equal(new[] { "/Users/", "  kunde/", "  arbeit" }, CommandText.Wrap("/Users/kunde/arbeit", 8));
        // Nach „=“, und als letzter Ausweg hart.
        Assert.Equal(new[] { "KEY=", "  valueval", "  uevalue" }, CommandText.Wrap("KEY=valuevaluevalue", 10));
        Assert.Equal(new[] { "abcd", "  ef", "  gh", "  ij" }, CommandText.Wrap("abcdefghij", 4));
        // Rangfolge: Leerzeichen, dann „=“, dann „/“; nie nach dem Punkt in „~/.claude“ – das Pfadstück wandert ganz weiter.
        Assert.Equal(new[] { "CLAUDE_CONFIG_DIR=", "  ~/.claude-alt claude" }, CommandText.Wrap("CLAUDE_CONFIG_DIR=~/.claude-alt claude", 29));
        Assert.Equal(new[] { "CLAUDE_CONFIG_DIR=", "  ~/.claude-alt", "  claude" }, CommandText.Wrap("CLAUDE_CONFIG_DIR=~/.claude-alt claude", 20));
        Assert.Equal(new[] { "~/", "  .claude-", "  alt" }, CommandText.Wrap("~/.claude-alt", 10));
        // „=“ geht vor „/“, auch wenn ein „/“ weiter hinten noch passen würde.
        Assert.Equal(new[] { "A=", "  b/c/d/", "  e/f" }, CommandText.Wrap("A=b/c/d/e/f", 9));
        // Für die Einrückung zu schmal: ohne Einrückung, aber nie breiter.
        Assert.Equal(new[] { "ab", "cd" }, CommandText.Wrap("abcd", 2));

        // Für jede Breite: keine Zeile zu lang, nichts geht verloren.
        var codex = AccountDiscovery.FolderKind.Codex.LoginCommand(@"C:\Users\Kunde A\.codex-arbeit");
        foreach (var cmd in new[] { command, codex, "CLAUDE_CONFIG_DIR=~/.claude-alt claude", "$env:CODEX_HOME=\"C:\\Daten\\.codex-arbeit\"; codex" })
            for (var width = 1; width <= 70; width++)
            {
                var lines = CommandText.Wrap(cmd, width);
                Assert.All(lines, line => Assert.True(line.Length <= width, $"{width}: „{line}“"));
                Assert.Equal(cmd.Replace(" ", ""), string.Concat(lines).Replace(" ", ""));
                Assert.DoesNotContain(lines, line => line.EndsWith("/.") || line.EndsWith("\\."));
            }
    }

    [Fact]
    public void HiddenAccountsAreNeitherVisibleNorPolled()
    {
        var folder = ClaudeFolder(".claude-privat", "u-6", "privat@example.com");
        var settings = new AppSettings();
        var discovery = new AccountDiscovery(home);
        var store = new UsageStore([], settings, cachePath: null, () => discovery.Accounts(AccountDiscovery.FolderKind.Claude));
        var id = new ClaudeProvider(folder).Id;
        Assert.Contains(store.PolledProviders, p => p.Id == id);

        settings.SetHidden(id, true);
        Assert.DoesNotContain(store.VisibleEntries, e => e.Id == id);
        Assert.DoesNotContain(store.PolledProviders, p => p.Id == id);
    }

    [Fact]
    public void LabelIsLimitedWhenSaved()
    {
        var settings = new AppSettings();
        settings.SetAccountLabel("claude", "  Kunde A Niederlassung Süd und Nord  ");
        Assert.Equal("Kunde A Niederlassung Sü", settings.AccountLabels["claude"]);
        Assert.Equal(AppSettings.MaxAccountLabelLength, settings.AccountLabels["claude"].Length);

        settings.SetAccountLabel("claude", " Privat ");
        Assert.Equal("Privat", settings.AccountLabels["claude"]);
        settings.SetAccountLabel("claude", "   ");
        Assert.False(settings.AccountLabels.ContainsKey("claude"));
    }

    [Fact]
    public void AddingTheSameFolderTwiceStoresItOnce()
    {
        var settings = new AppSettings();
        var folder = Path.Combine(home, "elsewhere", "claude-arbeit");
        settings.AddAccountFolder("claude", folder);
        settings.AddAccountFolder("claude", folder + Path.DirectorySeparatorChar);
        Assert.Single(settings.AccountFolders["claude"]);

        settings.RemoveAccountFolder("claude", folder);
        Assert.False(settings.AccountFolders.ContainsKey("claude"));
    }

    [Fact]
    public void AutomaticLabelNamesItsOrigin()
    {
        Assert.Equal(new AutoLabel("arbeit", LabelOrigin.Email), new AccountSource { Email = "arbeit@example.com", Name = "Arbeit" }.AutomaticLabelInfo);
        Assert.Equal(new AutoLabel("Kunde A", LabelOrigin.Name), new AccountSource { Name = "Kunde A" }.AutomaticLabelInfo);
        Assert.Equal(new AutoLabel("claude-privat", LabelOrigin.Folder), new AccountSource { Folder = Path.Combine(home, ".claude-privat") }.AutomaticLabelInfo);
        Assert.Null(new AccountSource().AutomaticLabelInfo);

        Assert.Equal("aus der E-Mail", LabelOrigin.Email.Description());
        Assert.Equal("aus dem Kontonamen", LabelOrigin.Name.Description());
        Assert.Equal("aus dem Ordnernamen", LabelOrigin.Folder.Description());

        // Eine eigene Bezeichnung geht vor, die automatische bleibt für den Platzhalter.
        var settings = new AppSettings();
        var provider = new ClaudeProvider(ClaudeFolder(".claude-kunde", "u-7", "kunde-a@example.com"));
        var store = new UsageStore([provider], settings, cachePath: null);
        settings.SetAccountLabel(provider.Id, "Kunde A");
        Assert.Equal("Kunde A", store.Label(provider));
        Assert.Equal(new AutoLabel("kunde-a", LabelOrigin.Email), store.AutomaticLabel(provider));
    }

    [Fact]
    public void AutomaticLabel()
    {
        Assert.Equal("frank", new AccountSource { Email = "frank@example.com", Name = "Frank" }.AutomaticLabel);
        Assert.Equal("Frank", new AccountSource { Name = "Frank" }.AutomaticLabel);
        Assert.Equal("claude-2", new AccountSource { Folder = Path.Combine(home, ".claude-2") }.AutomaticLabel);
        Assert.Null(new AccountSource().AutomaticLabel);
    }

    [Fact]
    public void TitleOnlyWithSeveralAccounts()
    {
        var settings = new AppSettings();
        var second = new ClaudeProvider(ClaudeFolder(".claude-2", "u-2", "second@example.com"));
        var store = new UsageStore([new ClaudeProvider(Path.Combine(home, "standard-dummy"), AccountOrigin.Standard), second], settings, cachePath: null);
        Directory.CreateDirectory(Path.Combine(home, "standard-dummy"));
        settings.SetAccountLabel(second.Id, "zweites");
        Assert.Equal("Claude · zweites", store.Title(second));

        settings.SetHidden(second.Id, true);
        Assert.Single(store.AccountsOfKind("claude"));
        Assert.Equal("Claude", store.Title(store.SortedProviders[0]));
    }

    [Fact]
    public void ReadsLogsOfAllAccountsAndSharedFoldersOnce()
    {
        var first = Directory.CreateDirectory(Path.Combine(home, ".claude", "projects", "C--repo")).FullName;
        var second = Directory.CreateDirectory(Path.Combine(home, ".claude-2", "projects", "C--other")).FullName;
        File.WriteAllText(Path.Combine(first, "a.jsonl"), ClaudeLogParserTests.Line.Replace("msg_1", "msg_a") + "\n");
        File.WriteAllText(Path.Combine(second, "b.jsonl"), ClaudeLogParserTests.Line.Replace("msg_1", "msg_b") + "\n");

        using var ledger = new UsageLedger(Path.Combine(home, "usage.sqlite"), home);
        var claudeRoot = Path.Combine(home, ".claude", "projects");
        var roots = new UsageLedger.Roots([claudeRoot, claudeRoot + Path.DirectorySeparatorChar, Path.Combine(home, ".claude-2", "projects")], []);
        Assert.True(ledger.Scan(roots));

        var day = UsageSummary.Key(DateOnly.FromDateTime(DateTimeOffset.Parse("2026-09-27T20:17:08.072Z").LocalDateTime));
        var row = Assert.Single(ledger.Rows("claude", day, day));
        Assert.Equal(220, row.Counts.Output);   // zwei Antworten, jede einmal
        Assert.False(ledger.Scan(roots));
    }
}
