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
    signal refreshRequested()

    property string page: "limits"
    property int rangeDays: 7
    property int now: 0   // bumped by a timer so "resets in" and pace texts stay current
    // one tab per account on "Limits"; "Verbrauch" is per provider, the logs name no account
    property int current: 0
    readonly property var accounts: info && info.accounts ? info.accounts : []
    readonly property var acc: accounts.length ? accounts[Math.min(current, accounts.length - 1)] : null

    spacing: 0
    Layout.preferredWidth: Kirigami.Units.gridUnit * 24
    Layout.preferredHeight: Kirigami.Units.gridUnit * 34

    function tint(pct) {
        return pct >= 100 ? Kirigami.Theme.negativeTextColor
             : pct >= 80 ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.positiveTextColor
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
    PC3.TabBar {
        id: tabBar
        Layout.fillWidth: true
        // a click sets currentIndex itself and would break a plain binding; Binding re-applies it
        Binding on currentIndex {
            value: view.page === "limits" ? Math.max(0, Math.min(view.current, view.accounts.length - 1)) : 0
        }
        Repeater {
            model: view.page === "limits" && view.accounts.length > 1 ? view.accounts : [{ title: "Claude" }]
            PC3.TabButton {
                required property var modelData
                required property int index
                text: "● " + modelData.title
                onClicked: if (view.page === "limits") view.current = index
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
                sourceComponent: !view.info || (view.page === "limits" && !view.acc) ? loading
                               : view.page === "limits" ? limitsPage : usagePage
            }
        }
    }

    // footer
    Kirigami.Separator { Layout.fillWidth: true }
    RowLayout {
        Layout.fillWidth: true
        Layout.margins: Kirigami.Units.largeSpacing
        PC3.Label {
            Layout.fillWidth: true
            elide: Text.ElideRight
            opacity: 0.7
            text: (view.updated ? "Stand " + Qt.formatTime(view.updated, "hh:mm") : "lädt …")
                  + (warning ? "  ·  ⚠ " + warning : "")
            readonly property var warning: view.page === "limits" ? (view.acc ? view.acc.error : null)
                                                                 : (view.info ? view.info.error : null)
        }
        PC3.ToolButton { icon.name: "view-refresh"; onClicked: view.refreshRequested() }
    }

    Component { id: loading; PC3.Label { text: "Lädt …"; opacity: 0.7 } }

    Component {
        id: limitsPage
        ColumnLayout {
            spacing: Kirigami.Units.largeSpacing * 1.5
            readonly property real worst: Math.max(0, Math.max.apply(null, view.acc.limits.map(function (l) { return l.pct })))
            RowLayout {
                Layout.fillWidth: true
                Kirigami.Heading { text: view.acc.title; level: 3 }
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
            PC3.Label {
                visible: view.acc.limits.length === 0
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                opacity: 0.7
                text: view.acc.error || "Noch kein Stand – fragt beim nächsten Takt ab."
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
                    text: view.accounts.length > 1 ? view.accounts.length + " Konten" : (view.acc ? view.acc.plan : "")
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
                      + (view.accounts.length > 1 ? " aller " + view.accounts.length + " Konten zusammen (die Protokolle nennen kein Konto)" : "")
                      + " × Listenpreis"
                      + (view.info.priceDate ? " (Stand " + view.info.priceDate + ")" : "")
                      + ", inkl. Cache-Tarife. Keine Abrechnungsdaten – nur, was derselbe Verbrauch über die API gekostet hätte."
                      + (usage.agg.unpriced ? " Modelle ohne Listenpreis sind nicht eingerechnet." : "")
            }
        }
    }

    Timer { interval: 30000; running: true; repeat: true; onTriggered: view.now++ }
}
