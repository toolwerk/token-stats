using System.Text;

namespace TokenStats.Model;

/// <summary>
/// Zerlegt Hinweise mit Befehlen in »…« in Satzteile und Befehle. Die Oberfläche setzt jeden Befehl
/// als eigene Zeile in Monospace und bricht ihn mit <see cref="Wrap"/> um – nie abgeschnitten.
/// </summary>
public static class CommandText
{
    public sealed record Part(string Text, bool IsCommand);

    public static List<Part> Split(string text)
    {
        var parts = new List<Part>();
        var prose = new StringBuilder();
        var afterCommand = false;
        var index = 0;
        while (index < text.Length)
        {
            var start = text.IndexOf('»', index);
            var end = start < 0 ? -1 : text.IndexOf('«', start + 1);
            if (end < 0)
            {
                prose.Append(text, index, text.Length - index);
                break;
            }
            var command = text[(start + 1)..end].Trim();
            var next = end + 1 < text.Length ? text[end + 1] : ' ';
            if (command.Length == 0 || char.IsLetterOrDigit(next) || next == '-')
            {
                // Teil eines Wortes („»agy«-Sitzung“): bleibt im Satz.
                prose.Append(text, index, end + 1 - index);
            }
            else
            {
                prose.Append(text, index, start - index);
                Flush();
                parts.Add(new Part(command, IsCommand: true));
                afterCommand = true;
            }
            index = end + 1;
        }
        Flush();
        return parts;

        void Flush()
        {
            var sentence = prose.ToString();
            prose.Clear();
            // Satzzeichen direkt hinter dem Befehl gehören zu ihm und fallen mit den »…« weg.
            sentence = afterCommand ? sentence.TrimStart('.', ',', ';', ':', ' ').Trim() : sentence.Trim();
            afterCommand = false;
            if (sentence.Length > 0) parts.Add(new Part(sentence, IsCommand: false));
        }
    }

    /// <summary>Einrückung der Folgezeilen eines umbrochenen Befehls, in Zeichen.</summary>
    public const int ContinuationIndent = 2;

    /// <summary>
    /// Bricht einen Befehl auf höchstens <paramref name="maxChars"/> Zeichen je Zeile um (Monospace,
    /// also Zeichen = Breite). Rangfolge innerhalb der Zeilenlänge: letztes Leerzeichen, sonst nach dem
    /// letzten „=“, sonst nach dem letzten „/“ oder „\“, sonst nach dem letzten von „- _ . :“, erst als
    /// letzter Ausweg hart. Das Zeichen bleibt am Zeilenende. Nie nach einem „.“, mit dem ein
    /// Ordnername beginnt („~/.claude“) – so wandert ein Pfadstück ganz in die nächste Zeile.
    /// Folgezeilen sind um <see cref="ContinuationIndent"/> Zeichen eingerückt, die Einrückung zählt mit; führende Leerzeichen einer Folgezeile entfallen.
    /// Keine Zeile wird länger als <paramref name="maxChars"/>.
    /// </summary>
    public static List<string> Wrap(string command, int maxChars)
    {
        maxChars = Math.Max(1, maxChars);
        // Ist der Platz zu knapp für Einrückung plus ein Zeichen, entfällt die Einrückung.
        var indent = maxChars - ContinuationIndent >= 1 ? new string(' ', ContinuationIndent) : "";
        var lines = new List<string>();
        var rest = command.Trim();
        while (rest.Length > 0)
        {
            var prefix = lines.Count == 0 ? "" : indent;
            var limit = maxChars - prefix.Length;
            if (rest.Length <= limit)
            {
                lines.Add(prefix + rest);
                break;
            }

            string line;
            // Leerzeichen an Index ≤ limit: Alles davor passt in die Zeile, das Leerzeichen selbst entfällt.
            var space = rest.LastIndexOf(' ', limit);
            if (space > 0)
            {
                line = rest[..space].TrimEnd();
                rest = rest[(space + 1)..].TrimStart();
            }
            else
            {
                var text = rest;
                var soft = LastBreak(text, limit, (c, _) => c == '=');
                if (soft < 0) soft = LastBreak(text, limit, (c, _) => c is '/' or '\\');
                if (soft < 0) soft = LastBreak(text, limit, (c, i) => c is '-' or '_' or ':' || (c == '.' && !StartsName(text, i)));
                var cut = soft >= 0 ? soft + 1 : limit;
                line = rest[..cut];
                rest = rest[cut..].TrimStart();
            }
            lines.Add(prefix + line);
        }
        return lines;
    }

    /// <summary>Letzte Stelle vor <paramref name="limit"/>, nach der umbrochen werden darf, sonst −1.</summary>
    static int LastBreak(string text, int limit, Func<char, int, bool> accepts)
    {
        for (var index = Math.Min(limit, text.Length) - 1; index >= 0; index--)
            if (accepts(text[index], index)) return index;
        return -1;
    }

    /// <summary>„.“ am Anfang eines Ordner- oder Dateinamens (<c>~/.claude</c>, <c>=.codex</c>) – dort kein Bruch.</summary>
    static bool StartsName(string text, int index) =>
        index == 0 || text[index - 1] is '/' or '\\' or '=' or '~' or ' ' or '"';
}
