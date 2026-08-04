#!/bin/bash
# Install usb-update scripts and systemd units on the target device. Run as root.
set -eu
src="$(cd "$(dirname "$0")" && pwd)"
dest=/usr/local/lib/usb-update

mkdir -p "$dest"
install -m 0755 "$src"/{common.sh,detect.sh,backup.sh,apply.sh,restore.sh,prompt.sh,validate.sh,usb-update-run.sh,uninstall.sh} "$dest/"
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

echo "Installed. Units enabled for next boot:"
systemctl list-unit-files 'usb-update*' --no-pager
