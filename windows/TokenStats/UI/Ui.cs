using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using TokenStats.Model;

namespace TokenStats.UI;

/// <summary>Kleine Bausteine, damit sich das Popup im Code so knapp liest wie die SwiftUI-Views.</summary>
static class Ui
{
    public static readonly FontFamily Font = new("Segoe UI Variable Text, Segoe UI");
    public static readonly FontFamily Icons = new("Segoe Fluent Icons, Segoe MDL2 Assets");
    public static readonly FontFamily Mono = new("Cascadia Mono, Consolas");

    public static TextBlock Text(string text, double size, Brush brush, FontWeight? weight = null) => new()
    {
        Text = text,
        FontFamily = Font,
        FontSize = size,
        FontWeight = weight ?? FontWeights.Normal,
        Foreground = brush,
        TextTrimming = TextTrimming.CharacterEllipsis,
    };

    public static TextBlock Wrapped(string text, double size, Brush brush)
    {
        var block = Text(text, size, brush);
        block.TextWrapping = TextWrapping.Wrap;
        block.TextTrimming = TextTrimming.None;
        return block;
    }

    /// <summary>
    /// Hinweis, der Befehle in »…« enthalten kann: Satzteile brechen normal um, jeder Befehl steht als
    /// eigene Zeile in Monospace (ohne »…«) und bricht nur an Leerzeichen. <paramref name="brush"/> und
    /// <paramref name="font"/> leer = vom Fenster erben (Einstellungen).
    /// </summary>
    public static StackPanel Prose(string text, double size, Brush? brush = null, FontFamily? font = null)
    {
        var panel = new StackPanel();
        foreach (var part in CommandText.Split(text))
        {
            FrameworkElement element;
            if (part.IsCommand)
            {
                element = Command(part.Text, size, brush);
            }
            else
            {
                var block = new TextBlock { Text = part.Text, FontSize = size, TextWrapping = TextWrapping.Wrap };
                if (brush is not null) block.Foreground = brush;
                if (font is not null) block.FontFamily = font;
                element = block;
            }
            Add(panel, element, 3);
        }
        return panel;
    }

    /// <summary>Befehlszeile: ein Block je durch Leerzeichen getrenntem Teil, jeder ohne Umbruch; Rechtsklick kopiert.</summary>
    public static WrapPanel Command(string command, double size, Brush? brush = null)
    {
        // Transparenter Hintergrund, damit der Rechtsklick auch zwischen den Teilen greift.
        var line = new WrapPanel { Background = Brushes.Transparent };
        foreach (var token in CommandText.Tokens(command))
        {
            var block = new TextBlock
            {
                Text = token,
                FontFamily = Mono,
                FontSize = size,
                TextWrapping = TextWrapping.NoWrap,
                TextTrimming = TextTrimming.None,
                Margin = new Thickness(0, 0, Math.Round(size * 0.6), 0),
            };
            if (brush is not null) block.Foreground = brush;
            line.Children.Add(block);
        }
        var copy = new MenuItem { Header = "Befehl kopieren" };
        copy.Click += (_, _) =>
        {
            // Die Zwischenablage kann kurz von einem anderen Programm belegt sein.
            try { Clipboard.SetText(command); }
            catch (System.Runtime.InteropServices.ExternalException) { }
        };
        var menu = new ContextMenu();
        menu.Items.Add(copy);
        line.ContextMenu = menu;
        return line;
    }

    public static TextBlock Icon(string glyph, double size, Brush brush) => new()
    {
        Text = glyph,
        FontFamily = Icons,
        FontSize = size,
        Foreground = brush,
        VerticalAlignment = VerticalAlignment.Center,
    };

    public static StackPanel Row(double spacing, params UIElement[] children) => Stack(Orientation.Horizontal, spacing, children);

    public static StackPanel Column(double spacing, params UIElement[] children) => Stack(Orientation.Vertical, spacing, children);

    static StackPanel Stack(Orientation orientation, double spacing, UIElement[] children)
    {
        var panel = new StackPanel { Orientation = orientation };
        foreach (var child in children) Add(panel, child, spacing);
        return panel;
    }

    /// <summary>Hängt ein Element mit Abstand zum vorigen an (StackPanel kennt kein Spacing).</summary>
    public static void Add(StackPanel panel, UIElement child, double spacing)
    {
        if (panel.Children.Count > 0 && child is FrameworkElement element)
        {
            var margin = element.Margin;
            element.Margin = panel.Orientation == Orientation.Horizontal
                ? margin with { Left = margin.Left + spacing }
                : margin with { Top = margin.Top + spacing };
        }
        panel.Children.Add(child);
    }

    /// <summary>Links und rechts ausgerichtet in einer Zeile, wie HStack mit Spacer.</summary>
    public static Grid Spread(UIElement left, UIElement? right, VerticalAlignment alignment = VerticalAlignment.Center)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (left is FrameworkElement l) l.VerticalAlignment = alignment;
        grid.Children.Add(left);
        if (right is not null)
        {
            if (right is FrameworkElement r)
            {
                r.VerticalAlignment = alignment;
                r.Margin = r.Margin with { Left = r.Margin.Left + 8 };
            }
            Grid.SetColumn(right, 1);
            grid.Children.Add(right);
        }
        return grid;
    }

    public static Border Divider(Brush brush) => new() { Height = 1, Background = brush, SnapsToDevicePixels = true };

    /// <summary>Klickbare Fläche ohne Button-Chrome, wie <c>.buttonStyle(.plain)</c>.</summary>
    public static Border Clickable(UIElement content, Action action, string? tooltip = null)
    {
        var border = new Border { Child = content, Background = Brushes.Transparent, Cursor = Cursors.Hand, ToolTip = tooltip };
        border.MouseLeftButtonUp += (_, e) =>
        {
            e.Handled = true;
            action();
        };
        return border;
    }
}
