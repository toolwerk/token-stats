import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami

// Satzteile und Befehle untereinander (parts aus text_parts in backend.py: [{kind: "text"|"cmd", text}]).
// Ein Befehl steht in Monospace auf einer eigenen Zeile und bricht nur an Leerzeichen um: je Token ein
// nicht umbrechender Text in einem Flow, damit Qt nie an „/“, „-“ oder „_“ trennt.
ColumnLayout {
    id: partsText
    property var parts: []
    property color color: Kirigami.Theme.textColor
    spacing: Kirigami.Units.smallSpacing

    Repeater {
        model: partsText.parts
        Item {
            id: part
            required property var modelData
            readonly property bool isCommand: modelData.kind === "cmd"
            Layout.fillWidth: true
            implicitHeight: isCommand ? tokens.implicitHeight : sentence.implicitHeight
            PC3.Label {
                id: sentence
                visible: !part.isCommand
                width: parent.width
                wrapMode: Text.Wrap
                elide: Text.ElideNone
                color: partsText.color
                text: part.isCommand ? "" : part.modelData.text
            }
            Flow {
                id: tokens
                visible: part.isCommand
                width: parent.width
                spacing: Kirigami.Units.smallSpacing * 2   // etwa die Breite eines Leerzeichens
                Repeater {
                    model: part.isCommand ? part.modelData.text.split(" ").filter(function (t) { return t.length > 0 }) : []
                    PC3.Label {
                        required property string modelData
                        text: modelData
                        wrapMode: Text.NoWrap
                        elide: Text.ElideNone
                        font.family: "monospace"
                        color: partsText.color
                    }
                }
            }
        }
    }
}
