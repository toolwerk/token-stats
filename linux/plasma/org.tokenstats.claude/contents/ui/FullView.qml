import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami
import "../code/util.js" as U

ColumnLayout {
    id: view
    property var info: null
    property var updated: null
    property bool expanded: false
    signal refreshRequested()

    property string page: "limits"
    property int rangeDays: 7
    property int now: 0   // bumped by a timer so "resets in" and pace texts stay current
    // gewähltes Konto auf „Limits“ (ID); leer oder verschwunden = das knappste. „Verbrauch“ gilt je Anbieter,
    // die Protokolle nennen kein Konto
    property string currentId: ""
    readonly property var accounts: info && info.accounts ? info.accounts : []
    readonly property var tightestAcc: accountById(info && info.tightest ? info.tightest : "") || (accounts.length ? accounts[0] : null)
    readonly property var acc: accountById(currentId) || tightestAcc
    // Konten, deren Protokolle zählen (ohne fehlende Ordner)
    readonly property int usageAccounts: info && info.usageAccounts !== undefined ? info.usageAccounts : accounts.length

    // beim Öffnen ist das knappste Konto gewählt
    onExpandedChanged: if (expanded) currentId = info && info.tightest ? info.tightest : ""

    spacing: 0
    Layout.preferredWidth: Kirigami.Units.gridUnit * 24
    Layout.preferredHeight: Kirigami.Units.gridUnit * 34

    // Rot für Sätze (Ordner fehlt): Kirigami.Theme.negativeTextColor (Breeze #da4453) hat auf Breeze hell
    // (#eff0f1) 3,7:1 und auf Breeze dunkel (#202326) 3,7:1. Ein Rot für beide gibt es nicht; darum je nach
    // Helligkeit des Grunds die Textfarben von macOS und Windows: #952f1a hell 6,8:1, #f59a8a dunkel 7,4:1.
    readonly property bool darkTheme: Kirigami.ColorUtils.brightnessForColor(Kirigami.Theme.backgroundColor) === Kirigami.ColorUtils.Dark
    readonly property color errorTextColor: darkTheme ? "#f59a8a" : "#952f1a"

    function tint(pct) {
        return pct >= 100 ? Kirigami.Theme.negativeTextColor
             : pct >= 80 ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.positiveTextColor
    }
    function accountById(id) {
        for (var i = 0; i < accounts.length; i++)
            if (accounts[i].id === id) return accounts[i]
        return null
    }
    // Zustandspunkt: Farbe des knappsten Limits, grau ohne Stand und bei Fehlerkonten
    function dotColor(a) {
        return !a || a.problem || a.pct === null || a.pct === undefined ? Kirigami.Theme.disabledTextColor : tint(a.pct)
    }

    // header: title and page switch
    RowLayout {
        Layout.fillWidth: true
        Layout.margins: Kirigami.Units.largeSpacing
        Kirigami.Heading { text: "Token Stats"; level: 2; Layout.fillWidth: true }
        RowLayout {
            spacing: 0
            PC3.Button { text: "Limits"; checkable: true; checked: view.page === "limits"; autoExclusive: true; onClicked: view.page = "limits" }
            PC3.Button { text: "Verbrauch"; checkable: true; checked: view.page === "usage"; autoExclusive: true; onClicked: view.page = "usage" }
        }
    }
    // Anbieter-Leiste: ein fester Eintrag „Claude“ auf beiden Seiten, der Punkt zeigt das knappste Konto
    PC3.TabBar {
        Layout.fillWidth: true
        PC3.TabButton {
            text: "Claude"
            checked: true
            contentItem: RowLayout {
                spacing: Kirigami.Units.smallSpacing
                Item { Layout.fillWidth: true }
                PC3.Label { text: "●"; color: view.dotColor(view.tightestAcc) }
                PC3.Label { text: "Claude" }
                Item { Layout.fillWidth: true }
            }
        }
    }
    // Kontoleiste: nur auf „Limits“ und ab zwei Konten; bricht um, nichts wird gekürzt
    Flow {
        id: accountBar
        visible: view.page === "limits" && view.accounts.length > 1
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.largeSpacing
        Layout.rightMargin: Kirigami.Units.largeSpacing
        Layout.topMargin: Kirigami.Units.smallSpacing
        Layout.bottomMargin: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.smallSpacing
        Repeater {
            model: view.accounts
            QQC2.AbstractButton {
                id: chip
                required property var modelData
                readonly property bool selected: view.acc !== null && view.acc.id === modelData.id
                readonly property color fg: modelData.problem ? Kirigami.Theme.disabledTextColor : Kirigami.Theme.textColor
                // „!“ nur als Zeichen; für Screenreader steht der Zustand in der Beschreibung
                text: modelData.label
                Accessible.description: modelData.problem ? "Fehler" : ""
                hoverEnabled: true
                // AbstractButton ist die Vorlage ohne eigene Größe; wie bei QQC2.Button aus Inhalt und Rand
                implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                                        implicitContentWidth + leftPadding + rightPadding)
                implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset,
                                         implicitContentHeight + topPadding + bottomPadding)
                width: Math.min(implicitWidth, accountBar.width)
                topPadding: Kirigami.Units.smallSpacing
                bottomPadding: Kirigami.Units.smallSpacing
                leftPadding: Kirigami.Units.largeSpacing
                rightPadding: Kirigami.Units.largeSpacing
                onClicked: view.currentId = modelData.id
                background: Rectangle {
                    radius: Kirigami.Units.smallSpacing * 2
                    readonly property color hl: Kirigami.Theme.highlightColor
                    readonly property color tc: Kirigami.Theme.textColor
                    color: chip.selected ? Qt.rgba(hl.r, hl.g, hl.b, 0.2)
                         : chip.hovered ? Qt.rgba(tc.r, tc.g, tc.b, 0.08) : "transparent"
                    border.width: 1
                    border.color: chip.selected ? hl : Qt.rgba(tc.r, tc.g, tc.b, 0.25)
                }
                contentItem: RowLayout {
                    spacing: Kirigami.Units.smallSpacing
                    PC3.Label { text: "●"; color: view.dotColor(chip.modelData); Layout.alignment: Qt.AlignTop }
                    PC3.Label {
                        text: chip.modelData.label
                        color: chip.fg
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                        // Platz für Punkt und „!“ freihalten, der Rest bricht um
                        Layout.maximumWidth: Math.max(Kirigami.Units.gridUnit * 2,
                                                      accountBar.width - chip.leftPadding - chip.rightPadding - Kirigami.Units.gridUnit * 2)
                    }
                    PC3.Label {
                        visible: chip.modelData.problem
                        text: "!"
                        font.bold: true
                        color: chip.fg
                        Layout.alignment: Qt.AlignTop
                    }
                }
            }
        }
    }
    Kirigami.Separator { Layout.fillWidth: true }

    PC3.ScrollView {
        Layout.fillWidth: true
        Layout.fillHeight: true
        contentWidth: availableWidth
        ColumnLayout {
            width: parent.width
            spacing: Kirigami.Units.largeSpacing
            Loader {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.largeSpacing
                sourceComponent: !view.info ? loading
                               : view.accounts.length === 0 ? emptyPage
                               : view.page !== "limits" ? usagePage
                               : view.acc.state === "missingFolder" ? missingPage : limitsPage
            }
        }
    }

    // footer
    Kirigami.Separator { Layout.fillWidth: true }
    RowLayout {
        Layout.fillWidth: true
        Layout.margins: Kirigami.Units.largeSpacing
        // Stand und Hinweis; ein Befehl im Hinweis steht auf eigener Zeile (PartsText)
        PartsText {
            Layout.fillWidth: true
            opacity: 0.7
            parts: {
                var stand = view.updated ? "Stand " + Qt.formatTime(view.updated, "hh:mm") : "lädt …"
                var warning = view.page === "limits" ? (view.acc && view.acc.errorParts ? view.acc.errorParts : [])
                            : (view.info && view.info.error ? [{ kind: "text", text: view.info.error }] : [])
                if (!warning.length) return [{ kind: "text", text: stand }]
                var prefix = stand + "  ·  ⚠"
                if (warning[0].kind === "text") {
                    var first = { kind: "text", text: prefix + " " + warning[0].text }
                    if (warning[0].segments)
                        first.segments = [{ text: prefix, mono: false }].concat(warning[0].segments)
                    return [first].concat(warning.slice(1))
                }
                return [{ kind: "text", text: prefix }].concat(warning)
            }
        }
        PC3.ToolButton { icon.name: "view-refresh"; onClicked: view.refreshRequested() }
    }

    Component { id: loading; PC3.Label { text: "Lädt …"; opacity: 0.7 } }

    Component {
        id: emptyPage
        ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            Kirigami.Heading {
                text: "Kein Claude-Konto gefunden"
                level: 3
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                elide: Text.ElideNone
            }
            PartsText {
                parts: view.info.emptyParts || []
                Layout.fillWidth: true
                opacity: 0.7
            }
        }
    }

    // Konto aus TOKENSTATS_CLAUDE_DIRS oder CLAUDE_CONFIG_DIR, dessen Ordner fehlt: wird nicht abgefragt
    Component {
        id: missingPage
        ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            Kirigami.Heading {
                text: view.acc.title
                level: 3
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                elide: Text.ElideNone
            }
            // Pfad wie in den Einstellungen auf macOS und Windows: eigene Zeile in Monospace, bricht wie ein Befehl um
            PartsText {
                parts: view.acc.folder ? [{ kind: "cmd", text: view.acc.folder }] : []
                Layout.fillWidth: true
                opacity: 0.7
            }
            PC3.Label {
                text: view.acc.missing || ""
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: view.errorTextColor
            }
            PC3.Label {
                text: view.acc.missingHint || ""
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                opacity: 0.7
            }
        }
    }

    Component {
        id: limitsPage
        ColumnLayout {
            spacing: Kirigami.Units.largeSpacing * 1.5
            readonly property real worst: Math.max(0, Math.max.apply(null, view.acc.limits.map(function (l) { return l.pct })))
            RowLayout {
                Layout.fillWidth: true
                // darf zweizeilig werden: schrumpft erst, wenn der Platz nicht reicht, und bricht dann um
                Kirigami.Heading {
                    text: view.acc.title
                    level: 3
                    Layout.fillWidth: true
                    Layout.maximumWidth: implicitWidth
                    wrapMode: Text.Wrap
                    elide: Text.ElideNone
                }
                PC3.Label { text: view.acc.plan; opacity: 0.7; font.family: "monospace" }
                Item { Layout.fillWidth: true }
                PC3.Label {
                    text: Math.round(worst) + " %"
                    font.bold: true
                    color: view.tint(worst)
                    leftPadding: 10; rightPadding: 10
                    background: Rectangle { radius: height / 2; color: "transparent"; border.width: 1; border.color: view.tint(worst) }
                }
            }
            PartsText {
                visible: view.acc.limits.length === 0
                Layout.fillWidth: true
                opacity: 0.7
                parts: view.acc.errorParts && view.acc.errorParts.length ? view.acc.errorParts
                     : [{ kind: "text", text: "Noch kein Stand – fragt beim nächsten Takt ab." }]
            }
            Repeater {
                model: view.acc.limits
                ColumnLayout {
                    id: row
                    required property var modelData
                    readonly property var st: { view.now; return U.limitState(modelData) }
                    Layout.fillWidth: true
                    spacing: 4
                    RowLayout {
                        Layout.fillWidth: true
                        Kirigami.Heading { text: row.modelData.title; level: 4 }
                        PC3.Label { text: row.modelData.sub; opacity: 0.7 }
                        Item { Layout.fillWidth: true }
                        Kirigami.Heading { text: Math.round(row.modelData.pct) + " %"; level: 4; color: view.tint(row.modelData.pct) }
                    }
                    Meter {
                        Layout.fillWidth: true
                        pct: row.modelData.pct
                        elapsed: row.st.elapsed
                        tint: view.tint(row.modelData.pct)
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        PC3.Label {
                            opacity: 0.7
                            text: {
                                if (!row.modelData.reset) return ""
                                var d = new Date(row.modelData.reset)
                                var soon = (d - Date.now()) < 86400000
                                return "Reset " + (soon ? Qt.formatTime(d, "hh:mm") : Qt.formatDateTime(d, "ddd hh:mm"))
                            }
                        }
                        Item { Layout.fillWidth: true }
                        PC3.Label {
                            visible: row.st.elapsed >= 0
                            color: view.tint(row.modelData.pct)
                            text: Math.abs(row.st.gap) < row.modelData.window * 0.02 ? "im Takt"
                                  : row.st.gap > 0 ? U.duration(row.st.gap) + " vorgegriffen"
                                                   : U.duration(-row.st.gap) + " ungenutzt"
                        }
                    }
                }
            }
            Kirigami.Separator { Layout.fillWidth: true; visible: view.acc.extra !== null }
            PC3.Label {
                visible: view.acc.extra !== null
                text: view.acc.extra || ""
                font.family: "monospace"
                padding: 8
                background: Rectangle { radius: 8; color: Kirigami.Theme.alternateBackgroundColor }
            }
        }
    }

    Component {
        id: usagePage
        ColumnLayout {
            id: usage
            spacing: Kirigami.Units.largeSpacing
            readonly property var agg: U.aggregate(view.info.usage, view.rangeDays, Qt.locale())
            RowLayout {
                Kirigami.Heading { text: "Claude"; level: 3 }
                PC3.Label {
                    text: view.usageAccounts > 1 ? view.usageAccounts + " Konten" : (view.acc ? view.acc.plan : "")
                    opacity: 0.7; font.family: "monospace"
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 0
                Repeater {
                    model: [{ t: "Heute", n: 1 }, { t: "7 Tage", n: 7 }, { t: "30 Tage", n: 30 },
                            { t: "Monat", n: new Date().getDate() }]
                    PC3.ToolButton {
                        required property var modelData
                        text: modelData.t
                        checkable: true
                        autoExclusive: true
                        checked: view.rangeDays === modelData.n
                        onClicked: view.rangeDays = modelData.n
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing
                Repeater {
                    model: [{ t: "TOKENS", v: U.fmtTokens(usage.agg.total), s: U.fmtTokens(usage.agg.cache) + " davon Cache" },
                            { t: "API-VERGLEICHSWERT", v: U.fmtMoney(usage.agg.value), s: "zu Listenpreisen" }]
                    Rectangle {
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        implicitHeight: card.implicitHeight + 24
                        radius: 12
                        color: Kirigami.Theme.alternateBackgroundColor
                        ColumnLayout {
                            id: card
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 2
                            PC3.Label { text: modelData.t; opacity: 0.7; font.pointSize: Kirigami.Theme.smallFont.pointSize }
                            Kirigami.Heading { text: modelData.v; level: 1 }
                            PC3.Label { text: modelData.s; opacity: 0.7; font.pointSize: Kirigami.Theme.smallFont.pointSize }
                        }
                    }
                }
            }
            BarChart { Layout.fillWidth: true; visible: usage.agg.series.length > 1; series: usage.agg.series }
            Repeater {
                model: usage.agg.models
                ColumnLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 0
                    RowLayout {
                        Layout.fillWidth: true
                        Kirigami.Heading { text: modelData.model; level: 4; Layout.fillWidth: true }
                        Kirigami.Heading { text: modelData.priced ? U.fmtMoney(modelData.value) : "k. A."; level: 4 }
                    }
                    PC3.Label {
                        opacity: 0.7
                        text: U.fmtTokens(modelData.in) + " Input · " + U.fmtTokens(modelData.out) + " Output · " + U.fmtTokens(modelData.cache) + " Cache"
                    }
                    Kirigami.Separator { Layout.fillWidth: true; Layout.topMargin: Kirigami.Units.smallSpacing }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Kirigami.Heading {
                    text: (view.rangeDays === 1 ? "Heute" : view.rangeDays + " Tage") + " · " + U.fmtTokens(usage.agg.total) + " Tokens"
                    level: 4
                    Layout.fillWidth: true
                }
                Kirigami.Heading { text: U.fmtMoney(usage.agg.value); level: 4 }
            }
            PC3.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                opacity: 0.7
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: "Lokal gezählte Tokens aus den Sitzungsprotokollen"
                      + (view.usageAccounts > 1 ? " aller " + view.usageAccounts + " Konten zusammen (die Protokolle nennen kein Konto)" : "")
                      + " × Listenpreis"
                      + (view.info.priceDate ? " (Stand " + view.info.priceDate + ")" : "")
                      + ", inkl. Cache-Tarife. Keine Abrechnungsdaten – nur, was derselbe Verbrauch über die API gekostet hätte."
                      + (usage.agg.unpriced ? " Modelle ohne Listenpreis sind nicht eingerechnet." : "")
            }
        }
    }

    Timer { interval: 30000; running: true; repeat: true; onTriggered: view.now++ }
}
