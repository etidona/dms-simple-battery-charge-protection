# DMS Simple Battery Charge Protection

A DankMaterialShell bar widget to turn battery charge protection ON or OFF with one click.

- **ON**: charging stops at 80%.
- **OFF**: charging goes up to 100%.

No percentages, no settings: just ON and OFF, the same on every laptop.

## How it works

- Click the icon to switch between ON and OFF. Hover over it to see the current state.
- The first time, you are asked for your password once. The widget installs a udev rule that lets your user change the charge threshold, so it never asks again.
- Your choice is kept after a reboot.
- If your laptop also has a start threshold, the widget lowers it to 75% when protection is ON and restores the original value when it is OFF.

| Icon | State |
|---|---|
| Battery with a check mark, accent color | ON |
| Full battery | OFF |
| Battery with a question mark, dimmed | Not supported on this laptop |

## Requirements

- DankMaterialShell, with its polkit agent running
- `pkexec` (polkit)
- A kernel driver that exposes `charge_control_end_threshold` for your battery. Check with:

```
ls /sys/class/power_supply/*/charge_control_end_threshold
```

If nothing is listed, your laptop is not supported.

Tested on Apple Silicon MacBooks with Asahi Linux.

## Install

```
git clone https://github.com/etidona/dms-simple-battery-charge-protection.git ~/.config/DankMaterialShell/plugins/simpleBatteryChargeProtection
```

Then enable it in Settings → Plugins and add the widget to your bar.

## Uninstall

Turn protection OFF before uninstalling, so both thresholds go back to their original values.

Uninstalling the plugin does not remove the udev rule it installed on first use. To remove it:

```
sudo rm /etc/udev/rules.d/99-dms-charge-protection.rules
sudo udevadm control --reload
```

To restore full charging right away:

```
echo 100 | sudo tee /sys/class/power_supply/*/charge_control_end_threshold
```

After the next reboot, the charge threshold goes back to your system's default and your user no longer has write access to it.
