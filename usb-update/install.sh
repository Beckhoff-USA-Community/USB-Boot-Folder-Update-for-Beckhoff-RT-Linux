#!/bin/bash
# Install usb-update scripts and systemd units on the target device. Run as root.
set -eu
src="$(cd "$(dirname "$0")" && pwd)"
dest=/usr/local/lib/usb-update

mkdir -p "$dest"
install -m 0755 "$src"/{common.sh,detect.sh,backup.sh,apply.sh,restore.sh,prompt.sh,validate.sh,ui-gate.sh,usb-update-run.sh,uninstall.sh} "$dest/"
# Don't clobber a locally tuned config on reinstall.
if [ -f "$dest/usb-update.conf" ]; then
    echo "keeping existing $dest/usb-update.conf (new default at usb-update.conf.dist)"
    install -m 0644 "$src/usb-update.conf" "$dest/usb-update.conf.dist"
else
    install -m 0644 "$src/usb-update.conf" "$dest/usb-update.conf"
fi

install -m 0644 "$src/usb-update.service" "$src/usb-update-validate.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable usb-update.service usb-update-validate.service

# Route the sway exec line that launches the TF1200 UI Client through
# ui-gate.sh, so the HMI browser waits for the boot-time update decision
# instead of racing the dialog. Idempotent: already-gated configs are kept.
gated=0
for cfg in /home/*/.config/sway/config /etc/sway/config /etc/sway/config.d/*; do
    [ -f "$cfg" ] || continue
    grep -q 'TF1200-UI-Client' "$cfg" || continue
    if grep -q "$dest/ui-gate.sh" "$cfg"; then
        gated=1
        continue
    fi
    sed -i -E "s|^([[:space:]]*exec[[:space:]]+)(.*TF1200-UI-Client)|\\1$dest/ui-gate.sh \\2|" "$cfg"
    if grep -q "$dest/ui-gate.sh" "$cfg"; then
        echo "gated the TF1200 UI Client launch in $cfg"
        gated=1
    fi
done
if [ "$gated" = 0 ]; then
    echo "WARNING: no sway config launching the TF1200 UI Client found -" >&2
    echo "the update dialog will appear over an already-running HMI client." >&2
fi

echo "Installed. Units enabled for next boot:"
systemctl list-unit-files 'usb-update*' --no-pager
