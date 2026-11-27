using System.Text;

namespace TokenStats.Model;

/// <summary>
/// Zerlegt Hinweise mit Befehlen in »…« in Satzteile und Befehle. Die Oberfläche setzt jeden Befehl
/// als eigene Zeile in Monospace, die nur an Leerzeichen umbricht – nie mitten in einem Pfad.
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

    /// <summary>Teile eines Befehls, an denen umbrochen werden darf: nur an Leerzeichen.</summary>
    public static string[] Tokens(string command) => command.Split(' ', StringSplitOptions.RemoveEmptyEntries);
}
