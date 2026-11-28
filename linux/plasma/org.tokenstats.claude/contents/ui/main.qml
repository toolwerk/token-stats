import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support

PlasmoidItem {
    id: root

    property var info: null
    property var updated: null
    // knappstes Limit über alle Konten
    readonly property var worstAccount: {
        var best = null, pct = -1
        var list = info && info.accounts ? info.accounts : []
        for (var i = 0; i < list.length; i++)
            for (var j = 0; j < list[i].limits.length; j++)
                if (list[i].limits[j].pct > pct) { pct = list[i].limits[j].pct; best = list[i] }
        return best
    }
    readonly property real worst: worstAccount
        ? Math.max.apply(null, worstAccount.limits.map(function (l) { return l.pct })) : 0
    readonly property string command: "python3 " + Qt.resolvedUrl("../code/backend.py").toString().replace("file://", "")

    Plasmoid.status: PlasmaCore.Types.ActiveStatus
    toolTipMainText: "Token Stats"
    toolTipSubText: info ? (worstAccount ? worstAccount.title : "Claude") + " " + Math.round(worst) + " %" : "lädt …"

    compactRepresentation: TrayIcon {
        pct: root.worst
        onClicked: root.expanded = !root.expanded
    }
    fullRepresentation: FullView {
        info: root.info
        updated: root.updated
        onRefreshRequested: root.refresh()
    }

    function refresh() {
        source.disconnectSource(command)
        source.connectSource(command)
    }

    P5Support.DataSource {
        id: source
        engine: "executable"
        connectedSources: [root.command]
        interval: 305000   // limits endpoint is rate limited: 300 s minimum (backend.py), a little more for the timer
        onNewData: function (sourceName, data) {
            if (!data["stdout"]) return
            try {
                root.info = JSON.parse(data["stdout"])
                root.updated = new Date()
            } catch (e) {
                console.warn("token stats: bad backend output", e)
            }
        }
    }
}
