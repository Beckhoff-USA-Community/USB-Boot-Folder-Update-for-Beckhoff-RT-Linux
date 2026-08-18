#!/bin/bash
# Boot-time orchestrator, run by usb-update.service before TwinCAT starts.
# detect -> (if actionable) prompt -> backup -> apply/restore -> continue boot.
# Always exits 0: an update problem must never block the machine from booting.
set -u
lib="$(cd "$(dirname "$0")" && pwd)"
. "$lib/common.sh"

mkdir -p "$STATE_DIR" /run/usb-update

# The HMI browser is held back by ui-gate.sh until we open its gate. The trap
# covers every exit path (no stick, refused package, failure, reboot), so a
# problem here can never leave the operator with a black screen; the explicit
# release_ui calls further down open the gate the moment a selection is made,
# without waiting for the copy work behind it to finish.
trap release_ui EXIT

reason=$("$lib/detect.sh")
rc=$?

case $rc in
    10|12)  # no stick / package already installed: silent, fast path
        exit 0
        ;;
    11)     # stick present but package invalid: tell the operator why
        "$lib/prompt.sh" --notify "Update refused: ${reason:-invalid package}"
        exit 0
        ;;
    13)     # RESTORE marker
        usb_unmount   # nothing further needed from the stick
        if ! ls -1d "$BACKUP_DIR"/Boot.* >/dev/null 2>&1; then
            "$lib/prompt.sh" --notify "Restore requested, but no backup exists."
            exit 0
        fi
        choice=$("$lib/prompt.sh" "Restore previous application?" "Restore")
        release_ui
        if [ "$choice" = "yes" ]; then
            if "$lib/restore.sh"; then
                log "run: restore applied"
            else
                "$lib/prompt.sh" --notify "Restore FAILED. No changes made."
            fi
        fi
        exit 0
        ;;
    0)      # valid update package, stick still mounted
        ;;
    *)
        log_err "run: detect.sh returned unexpected code $rc"
        usb_unmount
        exit 0
        ;;
esac

# Which parts does the package carry? (detect.sh already validated them.)
tc_pkg="$MOUNT_POINT/$PKG_TC_SUBDIR"
hmi_pkg="$MOUNT_POINT/$PKG_HMI_SUBDIR"
parts=()
[ -d "$tc_pkg" ] && parts+=("$tc_pkg")
[ -d "$hmi_pkg" ] && parts+=("$hmi_pkg")

if [ -d "$tc_pkg" ] && [ -d "$hmi_pkg" ]; then
    what="application + HMI"
elif [ -d "$hmi_pkg" ]; then
    what="HMI"
else
    what="application"
fi

version=$(sed -n 's/^version=//p' "$MOUNT_POINT/manifest.txt" 2>/dev/null | tr -d '\r')
# Keep short: swaynag draws this on one line, left of the buttons.
if [ -n "$version" ]; then
    msg="Install $what version $version?"
else
    msg="Install new $what from USB?"
fi

choice=$("$lib/prompt.sh" "$msg" "Update")
release_ui
if [ "$choice" != "yes" ]; then
    log "run: operator skipped the update"
    usb_unmount
    exit 0
fi

pkg_id=$(package_id "${parts[@]}")
if ! "$lib/backup.sh" >/dev/null; then
    "$lib/prompt.sh" --notify "Update aborted: backup failed. No changes made."
    usb_unmount
    exit 0
fi

if "$lib/apply.sh" "$MOUNT_POINT" "$pkg_id"; then
    if [ "${REBOOT_AFTER_UPDATE:-0}" = "1" ]; then
        log "run: update applied, restarting the IPC (REBOOT_AFTER_UPDATE=1); validation runs after the restart"
        usb_unmount
        ${REBOOT_CMD:-systemctl reboot}
        exit 0
    fi
    log "run: update applied ($what), boot continues with the new state"
else
    "$lib/prompt.sh" --notify "Update FAILED during copy. No changes made."
fi

usb_unmount
exit 0
