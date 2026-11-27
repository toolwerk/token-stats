using System.Windows;
using Forms = System.Windows.Forms;

namespace TokenStats.App;

public static class Program
{
    [STAThread]
    public static int Main()
    {
        // Agent-App ohne Taskleisten-Eintrag; alles hängt am Tray-Symbol. Nur eine Instanz je Benutzer.
        using var mutex = new Mutex(true, @"Local\TokenStats.Instance", out var isFirst);
        if (!isFirst) return 0;

        Forms.Application.EnableVisualStyles();
        // Kontextmenü am Tray-Symbol hell oder dunkel wie das System.
        Forms.Application.SetColorMode(Forms.SystemColorMode.System);

        var app = new Application
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown,
            // Windows-11-Steuerelemente im Einstellungsfenster, hell oder dunkel wie das System.
            ThemeMode = ThemeMode.System,
        };

#if DEBUG
        // Für die README: Popup und Tray-Symbol mit Demo-Werten als PNG, dann Ende.
        if (Environment.GetEnvironmentVariable("TOKENSTATS_SCREENSHOTS") is { Length: > 0 } directory)
        {
            app.Startup += (_, _) =>
            {
                try
                {
                    Screenshots.Run(directory);
                    app.Shutdown();
                }
                catch (Exception error)
                {
                    // Ohne Konsole (WinExe, CI-Lauf): Fehler neben die Bilder schreiben und mit Code 1 enden.
                    Directory.CreateDirectory(directory);
                    File.WriteAllText(Path.Combine(directory, "screenshots-error.txt"), error.ToString());
                    app.Shutdown(1);
                }
            };
            return app.Run();
        }
#endif

        using var tray = new TrayApp();
        app.Startup += (_, _) => tray.Start();
        return app.Run();
    }
}
