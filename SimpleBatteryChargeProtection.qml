import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    layerNamespacePlugin: "simple-battery-charge-protection"

    readonly property int protectedThreshold: 80
    readonly property int offThreshold: 100
    readonly property int protectedStartThreshold: 75
    readonly property string ruleFile: "/etc/udev/rules.d/99-dms-charge-protection.rules"

    // State read from sysfs
    property bool supported: false
    property string battery: ""
    property bool protectionOn: false
    property string startThreshold: "-"   // "-" = no start threshold file
    property bool writable: false

    property bool busy: false
    property bool pendingOn: false
    property bool restored: false

    readonly property string tooltipText: !supported ? "Charge protection not supported"
        : protectionOn ? "Charge protection: ON" : "Charge protection: OFF"
    readonly property string iconName: !supported ? "battery_unknown"
        : protectionOn ? "battery_status_good" : "battery_full"

    // Prints "<battery> <end> <start|-> <writable 0|1>" for the first battery with a charge threshold
    readonly property string detectScript: `
for d in /sys/class/power_supply/*; do
  [ "$(cat "$d/type" 2>/dev/null)" = Battery ] || continue
  [ -e "$d/charge_control_end_threshold" ] || continue
  s=-; [ -e "$d/charge_control_start_threshold" ] && s=$(cat "$d/charge_control_start_threshold")
  w=0; [ -w "$d/charge_control_end_threshold" ] && w=1
  echo "\${d##*/} $(cat "$d/charge_control_end_threshold") $s $w"
  exit 0
done`

    // Args: <battery> <end> <start|->. The start threshold is lowered before the end
    // threshold and restored after it, since some laptops reject end < start.
    readonly property string writeScript: `
d=/sys/class/power_supply/$1; e=$2; s=$3
ws() { [ "$s" = - ] || [ ! -w "$d/charge_control_start_threshold" ] || echo "$s" 2>/dev/null > "$d/charge_control_start_threshold"; true; }
[ "$e" -lt 100 ] && ws
echo "$e" > "$d/charge_control_end_threshold" || exit 1
[ "$e" -ge 100 ] && ws
exit 0`

    // Runs as root via pkexec. Args: <battery> <end> <start|-> <user>.
    // Installs the udev rule giving <user> write access, then writes the thresholds.
    readonly property string ruleScript: `
d=/sys/class/power_supply/$1
r="SUBSYSTEM==\\"power_supply\\", KERNEL==\\"$1\\""
for f in charge_control_end_threshold charge_control_start_threshold; do
  [ -e "$d/$f" ] && r="$r, RUN+=\\"/bin/chown $4 /sys%p/$f\\", RUN+=\\"/bin/chmod u+w /sys%p/$f\\""
done
printf '%s\\n' "$r" > ${ruleFile} || exit 2
udevadm control --reload
udevadm trigger "$d"
udevadm settle`

    function refresh() {
        if (!detectProc.running)
            detectProc.running = true;
    }

    function applyState(on) {
        if (busy || !supported)
            return;

        const end = on ? protectedThreshold : offThreshold;
        let start = "-";
        if (startThreshold !== "-") {
            if (on && parseInt(startThreshold) >= protectedThreshold) {
                pluginService?.savePluginData(pluginId, "originalStart", startThreshold);
                start = String(protectedStartThreshold);
            } else if (!on && pluginData.originalStart !== undefined) {
                start = String(pluginData.originalStart);
            }
        }

        const args = [battery, String(end), start];
        if (writable) {
            writeProc.command = ["sh", "-c", writeScript, "sh"].concat(args);
        } else {
            const user = Quickshell.env("USER") || "";
            if (!/^[A-Za-z0-9_.-]+$/.test(user)) {
                ToastService.showError("Could not change charge protection", "Unknown user name");
                return;
            }
            writeProc.command = ["pkexec", "/bin/sh", "-c", ruleScript + writeScript, "sh"].concat(args, [user]);
        }

        busy = true;
        pendingOn = on;
        writeProc.running = true;
    }

    Component.onCompleted: refresh()

    // Keeps every bar instance in sync after a change
    onPluginDataChanged: refresh()

    Process {
        id: detectProc
        command: ["sh", "-c", root.detectScript]
        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.trim().split(" ");
                if (parts.length !== 4 || !/^[A-Za-z0-9_.-]+$/.test(parts[0])) {
                    root.supported = false;
                    return;
                }
                root.battery = parts[0];
                root.protectionOn = parseInt(parts[1]) <= root.protectedThreshold;
                root.startThreshold = parts[2];
                root.writable = parts[3] === "1";
                root.supported = true;

                // Re-apply the saved state after a reboot
                if (!root.restored) {
                    root.restored = true;
                    const saved = root.pluginData.protectionOn;
                    if (saved !== undefined && root.writable && saved !== root.protectionOn)
                        root.applyState(saved);
                }
            }
        }
    }

    Process {
        id: writeProc
        stderr: StdioCollector {
            id: writeErr
        }
        onExited: exitCode => {
            root.busy = false;
            if (exitCode === 0) {
                root.pluginService?.savePluginData(root.pluginId, "protectionOn", root.pendingOn);
            } else if (exitCode !== 126 && exitCode !== 127) {
                // 126/127: password dialog dismissed or not authorized
                ToastService.showError("Could not change charge protection", writeErr.text.trim());
            }
            root.refresh();
        }
    }

    component Pill: Item {
        implicitWidth: root.iconSize
        implicitHeight: root.iconSize

        DankIcon {
            anchors.centerIn: parent
            name: root.iconName
            size: root.iconSize
            opacity: root.busy ? 0.5 : 1
            color: !root.supported ? Theme.withAlpha(Theme.widgetIconColor, 0.4)
                : root.protectionOn ? Theme.primary : Theme.widgetIconColor
        }

        MouseArea {
            id: pillArea
            anchors.fill: parent
            hoverEnabled: true
            // Handles the click itself: pillClickAction also fires on hover
            // when the bar opens widgets on hover
            acceptedButtons: Qt.LeftButton
            cursorShape: root.supported ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.applyState(!root.protectionOn)
            onEntered: {
                root.refresh();
                tooltipLoader.active = true;
                root.showTooltip(tooltipLoader.item, pillArea);
            }
            onExited: {
                tooltipLoader.item?.hide();
                tooltipLoader.active = false;
            }
        }

        // DTooltip opens its own window, so the text is not clipped by the bar
        Loader {
            id: tooltipLoader
            active: false
            sourceComponent: DTooltip {}
        }
    }

    // Same placement as the built-in bar widgets
    function showTooltip(tooltip, item) {
        if (!tooltip || !parentScreen)
            return;
        const edge = axis?.edge;
        if (isVertical) {
            const pos = item.mapToItem(null, item.width / 2, item.height / 2);
            const minY = parentScreen.y > 0 ? barThickness + barSpacing : 0;
            const isLeft = edge === "left";
            const x = isLeft ? (barThickness + barSpacing + Theme.spacingXS)
                : (parentScreen.width - barThickness - barSpacing - Theme.spacingXS);
            tooltip.show(tooltipText, x, pos.y + minY, parentScreen, isLeft, !isLeft);
        } else {
            const pos = item.mapToItem(null, item.width / 2, 0);
            const y = edge === "bottom"
                ? parentScreen.height - barThickness - barSpacing - Theme.spacingXS - (Theme.fontSizeSmall * 1.5 + Theme.spacingS * 2)
                : barThickness + barSpacing + Theme.spacingXS;
            tooltip.show(tooltipText, pos.x, y, parentScreen, false, false);
        }
    }

    horizontalBarPill: Component {
        Pill {
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    verticalBarPill: Component {
        Pill {
            anchors.horizontalCenter: parent.horizontalCenter
        }
    }
}
