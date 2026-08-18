#!/bin/bash
# Remove usb-update scripts and systemd units from the target device. Run as root.
# Runtime state (backups, installed-id) is kept unless --purge is given, so a
# later reinstall picks up where it left off.
set -eu

purge=0
force=0
for arg in "$@"; do
    case "$arg" in
        --purge) purge=1 ;;
        --force) force=1 ;;
        *) echo "usage: $0 [--purge] [--force]" >&2; exit 2 ;;
    esac
done

dest=/usr/local/lib/usb-update
conf="$dest/usb-update.conf"

# Pull paths out of the installed config with sed instead of sourcing it: the
# config executes code (id lookups, arrays) that can fail on a half-torn-down
# device, and we only need two literal values.
conf_val() {
    local v
    v=$(sed -n "s/^$1=//p" "$conf" 2>/dev/null | tail -n 1)
    printf '%s\n' "${v:-$2}"
}
state_dir=$(conf_val STATE_DIR /var/lib/usb-update)
mount_point=$(conf_val MOUNT_POINT /run/usb-update/mnt)

# A pending-validation marker means the last update/restore was never confirmed
# healthy: .old rollback state may still exist and validate.sh is the machinery
# that would offer the revert. Don't silently remove that safety net.
if [ -f "$state_dir/pending-validation" ] && [ "$force" != 1 ]; then
    echo "ERROR: $state_dir/pending-validation exists - the last update has not" >&2
    echo "been validated yet. Reboot so validation can finish (or resolve the" >&2
    echo "failed state), or re-run with --force to uninstall anyway." >&2
    exit 1
fi

systemctl disable usb-update.service usb-update-validate.service 2>/dev/null || true
rm -f /etc/systemd/system/usb-update.service /etc/systemd/system/usb-update-validate.service
systemctl daemon-reload

# Un-gate the TF1200 UI Client launch BEFORE removing $dest: a sway config
# exec'ing a deleted ui-gate.sh would leave the machine with no HMI at all.
for cfg in /home/*/.config/sway/config /etc/sway/config /etc/sway/config.d/*; do
    [ -f "$cfg" ] || continue
    if grep -q "$dest/ui-gate.sh" "$cfg"; then
        sed -i "s|$dest/ui-gate.sh ||g" "$cfg"
        echo "restored direct TF1200 UI Client launch in $cfg"
    fi
done

if mountpoint -q "$mount_point" 2>/dev/null; then
    umount "$mount_point" || echo "WARNING: failed to unmount $mount_point" >&2
fi
rm -rf /run/usb-update
rm -rf "$dest"

if [ "$purge" = 1 ]; then
    rm -rf "$state_dir"
    echo "Removed $state_dir (backups and installed-id)."
elif [ -d "$state_dir" ]; then
    echo "Kept $state_dir (backups and installed-id); use --purge to remove it."
fi

echo "Uninstalled. Units removed:"
systemctl list-unit-files 'usb-update*' --no-pager || true
