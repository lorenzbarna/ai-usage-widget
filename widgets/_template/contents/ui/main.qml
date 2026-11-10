import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PC3
import org.kde.plasma.plasma5support as P5
import org.kde.kirigami as Kirigami

// TEMPLATE for a new provider widget. Copy this folder to widgets/<provider>/, then fix every TODO below
// and in metadata.json. The UI expects `ai-usage <provider>` to print
//   {"at": unix, "plan": str, "session": Window|null, "week": Window|null}  with Window = {pct, reset, len}
//   A window key left out = the plan has no such limit: its row is hidden.
// If the provider's limits don't fit "5h + 7d" (other window lengths, credits, per-model caps), change the
// Repeater model and labels below: each widget owns its UI, nothing is shared.
PlasmoidItem {
    id: root
    readonly property string provider: "PROVIDER"  // TODO: key in ai-usage.py PROVIDERS
    readonly property color accent: "#888888"  // TODO: brand-ish dot colour
    property var usage: ({})
    property real now: Date.now() / 1000

    preferredRepresentation: fullRepresentation
    Plasmoid.backgroundHints: PlasmaCore.Types.DefaultBackground

    P5.DataSource {
        id: exec
        engine: "executable"
        onNewData: (source, d) => {
            disconnectSource(source)
            root.loading = false
            root.now = Date.now() / 1000
            let u
            try { u = JSON.parse(d.stdout) } catch (e) { u = { error: d.stderr || "no output" } }
            // On error keep showing the last good reading (and its time) with the error on top
            root.usage = u.error ? Object.assign({}, root.usage, { error: u.error, retryAt: root.now + (u.retry_after || 60) }) : u
        }
        // The " #<time>" shell comment makes each command a new source: the engine won't rerun a source it already has
        function run() { root.loading = true; root.askedAt = Date.now() / 1000; connectSource("python3 $HOME/.local/bin/ai-usage " + root.provider + " #" + Date.now()) }
    }
    property real askedAt: 0
    property bool loading: false
    // One 30s tick drives everything: refetch once the reading is 5 min old, or once an error's retry time
    // (60s, or the 429's retry-after) has passed. A fetch whose answer never arrives is retried after
    // 60s, so a dropped one can't freeze the widget.
    Timer {
        interval: 30000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: {
            root.now = Date.now() / 1000
            const stale = root.usage.error ? root.now >= root.usage.retryAt : !root.usage.at || root.now - root.usage.at >= 290
            if (stale && root.now - root.askedAt >= 60) { root.askedAt = root.now; exec.run() }
        }
    }

    // Pace: keep burning at the average rate since the window opened. In the first 10% of a window a few
    // percent would project to far over 100%, so judge only once enough time has passed (or a lot is used).
    function pace(w) {
        if (!w) return null
        const start = w.reset - w.len, el = Math.max(60, now - start), frac = Math.min(1, el / w.len)
        const rate = w.pct / el, proj = w.pct / frac
        const outAt = rate > 0 ? now + (100 - w.pct) / rate : Infinity
        const early = frac < 0.1 && w.pct < 20
        const status = early ? "ok" : proj >= 100 && outAt < w.reset ? "bad" : proj >= 80 ? "warn" : "ok"
        return { pct: w.pct, reset: w.reset, frac: frac, proj: proj, outAt: outAt, early: early, status: status }
    }
    readonly property var week: pace(usage.week)
    readonly property var session: pace(usage.session)

    function fmtLeft(s) {
        if (s <= 0) return "now"
        const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60)
        return d > 0 ? d + "d " + h + "h" : h > 0 ? h + "h " + m + "m" : m + "m"
    }
    function when(t) { return Qt.formatDateTime(new Date(t * 1000), "ddd hh:mm") }
    function statusColor(s) { return s === "bad" ? Kirigami.Theme.negativeTextColor : s === "warn" ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.positiveTextColor }

    function verdict(w) {
        if (w.early) return "just started"
        if (w.status === "bad") return "out " + when(w.outAt) + " · " + fmtLeft(w.reset - w.outAt) + " before reset"
        return (w.status === "warn" ? "tight" : "on pace") + " · ~" + Math.round(w.proj) + "% at reset"
    }

    fullRepresentation: Item {
        readonly property real pad: Kirigami.Units.smallSpacing
        // Text lines have empty space above/below the glyphs, more than the frame has at the sides: pull
        // top/bottom in by it so the visible margins match left/right. Measured, Breeze at default font size.
        readonly property real lineAir: 7
        readonly property real vpad: pad - lineAir
        Layout.minimumWidth: Kirigami.Units.gridUnit * 15
        Layout.preferredWidth: Kirigami.Units.gridUnit * 17
        // Height follows the content, so the padding is the same on all four sides
        Layout.minimumHeight: col.implicitHeight + 2 * vpad
        Layout.preferredHeight: Layout.minimumHeight
        Layout.maximumHeight: Layout.minimumHeight

        ColumnLayout {
            id: col
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: parent.pad; rightMargin: parent.pad }
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                Rectangle { width: 9; height: 9; radius: 5; color: root.accent }
                Kirigami.Heading { id: heading; level: 4; text: "NAME" }  // TODO: display name
                PC3.Label { text: root.usage.plan || ""; opacity: 0.6; font: Kirigami.Theme.smallFont }
                Item { Layout.fillWidth: true }
                PC3.Label { text: root.usage.at ? Qt.formatTime(new Date(root.usage.at * 1000), "hh:mm") : "…"; opacity: 0.6; font: Kirigami.Theme.smallFont }
                PC3.ToolButton {
                    icon.name: "view-refresh"; enabled: !root.loading; onClicked: exec.run()
                    padding: 0; Layout.preferredHeight: heading.implicitHeight; Layout.preferredWidth: Layout.preferredHeight  // no taller than the title
                    PC3.ToolTip.text: "Reload"; PC3.ToolTip.visible: hovered; PC3.ToolTip.delay: Kirigami.Units.toolTipDelay
                }
            }
            PC3.Label {
                visible: !!root.usage.error; text: root.usage.error || ""
                color: Kirigami.Theme.negativeTextColor; elide: Text.ElideRight; Layout.fillWidth: true; font: Kirigami.Theme.smallFont
            }

            Repeater {
                // A window the script leaves out is a limit the plan doesn't have (e.g. no 5h limit on Ultra): no row
                model: [["5h", root.session, "session"], ["7d", root.week, "week"]].filter(r => !root.usage.at || r[2] in root.usage)
                delegate: ColumnLayout {
                    required property var modelData
                    readonly property var w: modelData[1]
                    visible: !!w || !!root.usage.at  // no window running (e.g. no 5h session yet): empty bar
                    Layout.fillWidth: true
                    spacing: 2
                    RowLayout {
                        Layout.fillWidth: true
                        PC3.Label { text: modelData[0]; opacity: 0.6; Layout.preferredWidth: Kirigami.Units.gridUnit * 1.4 }
                        Item {
                            Layout.fillWidth: true; height: 10
                            Rectangle { anchors.fill: parent; radius: 5; color: Qt.alpha(Kirigami.Theme.textColor, 0.12) }
                            Rectangle { width: parent.width * Math.min(1, w ? w.pct / 100 : 0); height: parent.height; radius: 5; color: w ? root.statusColor(w.status) : "transparent" }
                            // where an even burn would be now
                            Rectangle { visible: !!w; x: parent.width * (w ? w.frac : 0) - 1; y: -4; width: 2; height: parent.height + 8; radius: 1; color: Kirigami.Theme.textColor }
                        }
                        PC3.Label { text: w ? Math.round(w.pct) + "%" : "0%"; Layout.preferredWidth: Kirigami.Units.gridUnit * 2.2; horizontalAlignment: Text.AlignRight }
                    }
                    PC3.Label {
                        Layout.leftMargin: Kirigami.Units.gridUnit * 1.4 + Kirigami.Units.smallSpacing
                        Layout.fillWidth: true; elide: Text.ElideRight; font: Kirigami.Theme.smallFont
                        textFormat: Text.StyledText
                        text: w ? "<font color='" + root.statusColor(w.status) + "'>" + root.verdict(w) + "</font> · resets " + root.fmtLeft(w.reset - root.now) : "not started"
                        opacity: 0.9
                    }
                }
            }
        }
    }

    MouseArea { anchors.fill: parent; onClicked: exec.run() }
}
