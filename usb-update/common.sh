#!/bin/bash
# Shared helpers for usb-update scripts. Source this, don't execute it.

USB_UPDATE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$USB_UPDATE_LIB/usb-update.conf"

# Fixed paths/accounts, identical on all supported devices — deliberately
# constants here, not settings in usb-update.conf.
# Where TwinCAT keeps the boot folder on Linux targets.
BOOT_DIR=/etc/TwinCAT/3.1/Boot
# TwinCAT HMI (TF2000) server state and the account that owns it (chowned by
# name; uids differ between devices). HMI_INSTALL_CHECK existing is how we
# decide the target has the HMI server at all; sticks with an HMI part are
# refused on devices without it.
HMI_DIR=/var/lib/tchmisrv
HMI_USER=tchmisrv
HMI_INSTALL_CHECK=/etc/TwinCAT/Functions/TF2000-HMI-Server/TcHmiSrv
# Marker that opens the HMI-browser gate: ui-gate.sh (run by sway in place of
# the TF1200 UI Client) holds the client back until this file exists, so the
# boot dialogs get the screen to themselves. Lives on the /run tmpfs, i.e. it
# is gone on every boot until usb-update-run.sh recreates it.
UI_RELEASE_FILE=/run/usb-update/ui-release

# log [-p <priority>] <message>...
# Default priority is notice; failure paths use log_err/log_warn so that
# `journalctl -t usb-update -p err` (or -p warning) surfaces them.
log() {
    local prio=notice
    if [ "${1:-}" = "-p" ]; then
        prio=$2
        shift 2
    fi
    logger -p "user.$prio" -t "$LOG_TAG" -- "$@"
    echo "$LOG_TAG: $*" >&2
}

log_warn() { log -p warning "$@"; }
log_err()  { log -p err "$@"; }

die() {
    log_err "ERROR: $*"
    exit 1
}

# Content id of a package: hash of all file hashes + paths, over every part
# directory given (TwinCAT boot folder and/or HMI folder — pass them in a
# fixed order). Used for stick-left-in idempotency (compare against
# $STATE_DIR/installed-id).
package_id() {
    local d
    for d in "$@"; do
        (cd "$d" && find . -type f -print0 | sort -z | xargs -0 sha256sum)
    done | sha256sum | cut -d' ' -f1
}

# --- TwinCAT HMI (TF2000) helpers -----------------------------------------
# The whole HMI server state lives under $HMI_DIR: TcHmiSrv.Service.Config.json
# plus service/<Instance>/ per published project. TcHmiSrv.service is
# After=TcSystemServiceUm.service, so everything here runs before the HMI
# server has started — no systemctl stop needed on the boot path.

hmi_installed() {
    [ -e "$HMI_INSTALL_CHECK" ]
}

hmi_config_json() {
    printf '%s\n' "$HMI_DIR/TcHmiSrv.Service.Config.json"
}

# Swap staged HMI state into place, keeping the previous state as
# service.old / .json.old until validation passes (mirrors Boot/Boot.old).
# $1 = staged service dir (moved into place), $2 = staged config json file.
hmi_swap() {
    local svc="$HMI_DIR/service" json
    json=$(hmi_config_json)
    mkdir -p "$HMI_DIR"
    rm -rf "$svc.old" "$json.old"
    [ -d "$svc" ] && mv "$svc" "$svc.old"
    mv "$1" "$svc"
    [ -f "$json" ] && mv "$json" "$json.old"
    mv "$2" "$json"
    sync
}

# True if a not-yet-validated HMI swap left rollback state behind.
hmi_old_present() {
    local json
    json=$(hmi_config_json)
    [ -d "$HMI_DIR/service.old" ] || [ -f "$json.old" ]
}

# Put the pre-swap HMI state back (failed state kept at .failed, mirroring
# Boot.failed). No-op unless hmi_old_present.
hmi_revert() {
    local svc="$HMI_DIR/service" json
    json=$(hmi_config_json)
    hmi_old_present || return 0
    rm -rf "$svc.failed" "$json.failed"
    [ -d "$svc" ] && mv "$svc" "$svc.failed"
    [ -d "$svc.old" ] && mv "$svc.old" "$svc"
    [ -f "$json" ] && mv "$json" "$json.failed"
    [ -f "$json.old" ] && mv "$json.old" "$json"
    sync
}

# Drop rollback/failed HMI state after successful validation.
hmi_cleanup_old() {
    local json
    json=$(hmi_config_json)
    rm -rf "$HMI_DIR/service.old" "$HMI_DIR/service.failed" \
           "$json.old" "$json.failed"
}

# This device's type, for the manifest target check. TARGET_TYPE from the
# config wins; otherwise ask the hardware: DMI product name (full ordering
# number, e.g. "CX9240-0215"), falling back to the device-tree model with the
# "Beckhoff " vendor prefix stripped.
device_target() {
    if [ -n "${TARGET_TYPE:-}" ]; then
        printf '%s\n' "$TARGET_TYPE"
        return
    fi
    local t
    t=$(tr -d '\0' < /sys/class/dmi/id/product_name 2>/dev/null)
    if [ -z "$t" ] && [ -r /proc/device-tree/model ]; then
        t=$(tr -d '\0' < /proc/device-tree/model)
        t="${t#Beckhoff }"
    fi
    printf '%s\n' "${t:-unknown}" | sed 's/[[:space:]]*$//'
}

# True if $1 is a case-insensitive prefix of this device's type, so
# target=CX9240 accepts a CX9240-0215 but refuses a CX7000.
target_matches() {
    local want="${1,,}" have
    have=$(device_target)
    case "${have,,}" in
        "$want"*) return 0 ;;
        *)        return 1 ;;
    esac
}

# Open the HMI-browser gate (see UI_RELEASE_FILE above). Safe to call more
# than once; never fails the caller.
release_ui() {
    mkdir -p "$(dirname "$UI_RELEASE_FILE")"
    touch "$UI_RELEASE_FILE" 2>/dev/null || true
}

usb_mounted() {
    mountpoint -q "$MOUNT_POINT"
}

usb_unmount() {
    if usb_mounted; then
        umount "$MOUNT_POINT" || log_warn "WARNING: failed to unmount $MOUNT_POINT"
    fi
}
