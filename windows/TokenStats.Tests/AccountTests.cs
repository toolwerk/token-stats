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
            $$$"""{"oauthAccount":{"accountUuid":"{{{uuid}}}","emailAddress":"{{{email}}}","displayName":"Frank"}}""");
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
        Assert.True(found[0].IsDefaultAccount);
        Assert.Equal(["second@example.com", "work@example.com"], found.Skip(1).Select(p => p.Source.Email).Order());
        Assert.All(found.Skip(1), p => Assert.Equal(AccountOrigin.Detected, p.Source.Origin));
    }

    [Fact]
    public void SkipsDuplicateLoginsAndKeepsManualFolders()
    {
        ClaudeFolder(".claude-2", "u-2", "second@example.com");
        var copy = ClaudeFolder(Path.Combine("elsewhere", "claude-copy"), "u-2", "second@example.com");
        var manual = ClaudeFolder(Path.Combine("elsewhere", "claude-firma"), "u-9", "firma@example.com");

        var folders = new Dictionary<string, List<string>> { ["claude"] = [copy, manual, manual] };
        var found = new AccountDiscovery(home, folders).Accounts(AccountDiscovery.FolderKind.Claude).Skip(1).ToList();
        Assert.Equal(["second@example.com", "firma@example.com"], found.Select(p => p.Source.Email));
        Assert.Equal(AccountOrigin.Manual, found[^1].Source.Origin);
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
