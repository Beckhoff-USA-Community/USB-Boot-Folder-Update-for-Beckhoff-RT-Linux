#!/bin/bash
# Detect and validate a USB update stick.
#
# Exit codes:
#   0  - valid update package present (stick left mounted read-only at MOUNT_POINT)
#   10 - no labeled stick present
#   11 - stick present but package invalid (reason on stdout, stick unmounted)
#   12 - package matches the currently installed version (no-op, stick unmounted)
#   13 - RESTORE marker present (stick left mounted read-only at MOUNT_POINT)
set -u
. "$(dirname "$0")/common.sh"

# Find the stick by label, case-insensitively (FAT uppercases labels).
find_stick() {
    local link name
    for link in /dev/disk/by-label/*; do
        [ -e "$link" ] || continue
        name=$(basename "$link")
        if [ "${name^^}" = "${USB_LABEL^^}" ]; then
            printf '%s\n' "$link"
            return 0
        fi
    done
    return 1
}

# After a hard power cycle the stick re-enumerates from cold and can show up
# seconds after this service starts — poll, exiting early once it appears.
usb_wait="${USB_WAIT_SECS:-10}"
waited=0
dev=""
while :; do
    dev=$(find_stick) && break
    [ "$waited" -ge "$usb_wait" ] && break
    sleep 1
    waited=$((waited + 1))
done

if [ -z "$dev" ]; then
    log "detect: no stick with label $USB_LABEL (after waiting ${usb_wait}s for USB enumeration)"
    exit 10
fi
[ "$waited" -gt 0 ] && log "detect: stick appeared after ${waited}s (USB enumeration delay)"

mkdir -p "$MOUNT_POINT"
usb_unmount   # clear any leftover mount from an interrupted previous run
if ! mount -o ro "$dev" "$MOUNT_POINT"; then
    log_err "detect: stick found ($dev) but mount failed"
    exit 11
fi

if [ -e "$MOUNT_POINT/RESTORE" ]; then
    log "detect: RESTORE marker found on stick"
    exit 13
fi

refuse() {
    log_err "detect: package invalid - $1"
    echo "$2"
    usb_unmount
    exit 11
}

# Stick layout: TwinCAT/Boot and/or "TwinCAT HMI"/<Instance>/ at the root.
tc_pkg="$MOUNT_POINT/$PKG_TC_SUBDIR"
hmi_pkg="$MOUNT_POINT/$PKG_HMI_SUBDIR"

if [ ! -d "$tc_pkg" ] && [ ! -d "$hmi_pkg" ]; then
    refuse "neither $PKG_TC_SUBDIR nor $PKG_HMI_SUBDIR found on stick" \
           "no update content on stick"
fi

if [ -d "$tc_pkg" ] && [ ! -f "$tc_pkg/CurrentConfig.xml" ]; then
    refuse "$PKG_TC_SUBDIR/CurrentConfig.xml missing" "Boot folder incomplete"
fi

if [ -d "$hmi_pkg" ]; then
    hmi_installed || refuse "stick has an HMI part but this device has no TF2000 HMI server" \
                            "this device has no HMI server installed"
    found=0
    for inst in "$hmi_pkg"/*/; do
        [ -d "$inst" ] || continue
        found=1
        name=$(basename "$inst")
        case "$name" in
            *[!A-Za-z0-9._-]*) refuse "HMI instance name '$name' contains unsafe characters" \
                                      "invalid HMI folder name: $name" ;;
        esac
        [ -f "$inst/storage.db" ] || refuse "HMI instance '$name' has no storage.db" \
                                            "HMI folder $name incomplete"
        [ -d "$inst/www" ] || refuse "HMI instance '$name' has no www folder" \
                                     "HMI folder $name incomplete"
    done
    [ "$found" = 1 ] || refuse "$PKG_HMI_SUBDIR contains no instance folder" \
                               "HMI folder on stick is empty"
fi

# Optional manifest at the stick root: key=value lines. Only 'target' is
# enforced; 'version' is displayed in the dialog if present.
if [ -f "$MOUNT_POINT/manifest.txt" ]; then
    target=$(sed -n 's/^target=//p' "$MOUNT_POINT/manifest.txt" | tr -d '\r')
    if [ -n "$target" ] && ! target_matches "$target"; then
        this_device=$(device_target)
        log_err "detect: manifest target '$target' does not match this device ('$this_device')"
        echo "package is for $target, not $this_device"
        usb_unmount
        exit 11
    fi
fi

parts=()
[ -d "$tc_pkg" ] && parts+=("$tc_pkg")
[ -d "$hmi_pkg" ] && parts+=("$hmi_pkg")
id=$(package_id "${parts[@]}")
installed=$(cat "$STATE_DIR/installed-id" 2>/dev/null || true)
if [ -n "$installed" ] && [ "$id" = "$installed" ]; then
    log "detect: package $id already installed, nothing to do"
    usb_unmount
    exit 12
fi

# A package that was applied but not yet validated (the swap completed and was
# verified, then the machine restarted with the stick still in — e.g. with
# REBOOT_AFTER_UPDATE=1) must not be offered again: validate.sh records it as
# installed after TwinCAT starts this boot.
pending=$(cat "$STATE_DIR/pending-validation" 2>/dev/null || true)
if [ -n "$pending" ] && [ "$id" = "$pending" ]; then
    log "detect: package $id already applied, awaiting validation, nothing to do"
    usb_unmount
    exit 12
fi

log "detect: valid update package found (id $id)"
exit 0
