import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami
import "../code/util.js" as U

// Satzteile und Befehle untereinander (parts aus inline_parts in backend.py: [{kind: "text"|"cmd", text, segments}]).
// Kurze Befehle stehen als Segment im Satz (Monospace).
// Ein längerer Befehl steht in Monospace auf eigenen Zeilen, umgebrochen mit U.wrapCommand nach der verfügbaren Breite
// (zuerst an Leerzeichen, dann nach / = _ - . :, zuletzt hart; Folgezeilen 2 Zeichen eingerückt). Je Zeile ein
// nicht umbrechender Text, damit Qt nicht selbst trennt; nie abgeschnitten, nie breiter als verfügbar.
ColumnLayout {
    id: partsText
    property var parts: []
    property color color: Kirigami.Theme.textColor
    spacing: Kirigami.Units.smallSpacing

    FontMetrics {
        id: mono
        font.family: "monospace"
        font.pointSize: Kirigami.Theme.defaultFont.pointSize
    }

    Repeater {
        model: partsText.parts
        Item {
            id: part
            required property var modelData
            readonly property bool isCommand: modelData.kind === "cmd"
            Layout.fillWidth: true
            implicitHeight: isCommand ? lines.implicitHeight : sentence.implicitHeight
            // Zeichen je Zeile aus der Breite; ändert sich die Breite, bricht der Befehl neu um
            // (averageCharacterWidth hält die Bindung bei Schriftwechseln aktuell, advanceWidth misst genau)
            readonly property int maxChars: Math.max(1, Math.floor(width / Math.max(1, mono.averageCharacterWidth,
                                                                                    mono.advanceWidth("0"))))
            PC3.Label {
                id: sentence
                visible: !part.isCommand
                width: parent.width
                wrapMode: Text.Wrap
                elide: Text.ElideNone
                color: partsText.color
                // kurze Befehle im Satz (Segmente aus inline_parts) in Monospace, sonst schlichter Text
                readonly property bool rich: !part.isCommand && U.hasMono(part.modelData.segments)
                textFormat: rich ? Text.RichText : Text.PlainText
                text: part.isCommand ? "" : rich ? U.segmentsRich(part.modelData.segments) : part.modelData.text
            }
            Column {
                id: lines
                visible: part.isCommand
                width: parent.width
                Repeater {
                    model: part.isCommand ? U.wrapCommand(part.modelData.text, part.maxChars, 2) : []
                    PC3.Label {
                        required property string modelData
                        text: modelData
                        textFormat: Text.PlainText   // Einrückung aus Leerzeichen bleibt erhalten
                        wrapMode: Text.NoWrap
                        elide: Text.ElideNone
                        font: mono.font
                        color: partsText.color
                    }
                }
            }
        }
    }
}
