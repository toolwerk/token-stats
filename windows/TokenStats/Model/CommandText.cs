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

    /// <summary>Zeichen, nach denen ein zu langer Teil umbrechen darf; das Zeichen bleibt am Zeilenende.</summary>
    static readonly char[] SoftBreaks = ['/', '\\', '=', '_', '-', '.', ':'];

    /// <summary>Einrückung der Folgezeilen eines umbrochenen Befehls, in Zeichen.</summary>
    public const int ContinuationIndent = 2;

    /// <summary>
    /// Bricht einen Befehl auf höchstens <paramref name="maxChars"/> Zeichen je Zeile um (Monospace,
    /// also Zeichen = Breite): zuerst am letzten Leerzeichen, sonst nach dem letzten von / \ = _ - . :,
    /// erst als letzter Ausweg hart. Folgezeilen sind um <see cref="ContinuationIndent"/> Zeichen
    /// eingerückt, die Einrückung zählt mit; führende Leerzeichen einer Folgezeile entfallen.
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
                var soft = rest.LastIndexOfAny(SoftBreaks, limit - 1);
                var cut = soft >= 0 ? soft + 1 : limit;
                line = rest[..cut];
                rest = rest[cut..].TrimStart();
            }
            lines.Add(prefix + line);
        }
        return lines;
    }
}
