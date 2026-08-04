#!/bin/bash
# Post-update validation, run After=TcSystemServiceUm (and TcHmiSrv, where it
# exists) on every boot. Cheap no-op unless apply.sh/restore.sh armed a
# pending-validation marker.
#
# Success = ADS state RUN (polled via tcadstool) AND, on devices with enabled
# HMI instances, the TF2000 server answering on HMI_URL. TwinCAT failure is
# detected fast by watching the current boot's TcSystemServiceUm journal for
# "TwinCAT system start completed. AdsState: >N<" — a non-RUN N means the boot
# folder didn't load and there is no point waiting out VALIDATE_TIMEOUT
# (which remains as a backstop if that message never appears). On a TwinCAT
# failure the error-priority TcSystemServiceUm entries of this boot (the
# actual cause, e.g. missing licenses) are copied into our own log at err
# priority — see TC_ERR_REPORT_LINES.
#
# On failure the .old rollback state is always kept. With
# PROMPT_REVERT_ON_FAILURE=1 the operator is offered an on-screen revert to
# the previous working state — Boot folder AND HMI state together, whichever
# were swapped (the machine reboots to load them, and the reverted boot is
# validated too); otherwise a "contact service" notice is shown and the failed
# state is left for a technician. The marker is kept on failure, so every boot
# in a failed state re-offers the choice.
set -u
. "$(dirname "$0")/common.sh"

# ADS constants, not config: the loopback NetID always addresses the local
# TwinCAT runtime, and 5 is the ADS-defined RUN state.
AMS_NETID=127.0.0.1.1.1
ADS_RUN_STATE=5

marker="$STATE_DIR/pending-validation"
[ -f "$marker" ] || exit 0

pkg_id=$(cat "$marker")
log "validate: checking system state after update ($pkg_id)"

# Latest "start completed" AdsState reported by TwinCAT this boot, if any.
completed_state() {
    journalctl -b -t TcSystemServiceUm -o cat 2>/dev/null \
        | sed -n 's/.*TwinCAT system start completed\. AdsState: >\([0-9]*\)<.*/\1/p' \
        | tail -n 1
}

waited=0
state=""
fail_fast=""
while [ "$waited" -lt "$VALIDATE_TIMEOUT" ]; do
    state=$(tcadstool "$AMS_NETID" state 2>/dev/null | tr -d '[:space:]')
    [ "$state" = "$ADS_RUN_STATE" ] && break
    done_state=$(completed_state)
    if [ -n "$done_state" ] && [ "$done_state" != "$ADS_RUN_STATE" ]; then
        fail_fast=$done_state
        break
    fi
    sleep 2
    waited=$((waited + 2))
done

failure=""
tc_failed=""
if [ "$state" != "$ADS_RUN_STATE" ]; then
    tc_failed=1
    if [ -n "$fail_fast" ]; then
        failure="TwinCAT start completed in state '$fail_fast', not RUN ($ADS_RUN_STATE); detected after ${waited}s"
    else
        failure="TwinCAT did not reach RUN within ${VALIDATE_TIMEOUT}s (last state: '${state:-none}')"
    fi
fi

# HMI health: only meaningful when the device has the TF2000 server with
# enabled instances configured (and the unit isn't deliberately disabled).
# TwinCAT failure skips this — one failure is enough, and the revert restores
# both halves anyway.
hmi_check_expected() {
    hmi_installed || return 1
    grep -q '"enabled"[[:space:]]*:[[:space:]]*true' "$(hmi_config_json)" 2>/dev/null || return 1
    systemctl is-enabled --quiet TcHmiSrv.service 2>/dev/null
}

if [ -z "$failure" ] && hmi_check_expected; then
    hmi_waited=0
    hmi_ok=""
    while [ "$hmi_waited" -lt "$HMI_VALIDATE_TIMEOUT" ]; do
        if curl -fsS -o /dev/null --max-time 5 "$HMI_URL"; then
            hmi_ok=1
            break
        fi
        sleep 2
        hmi_waited=$((hmi_waited + 2))
    done
    if [ -n "$hmi_ok" ]; then
        log "validate: HMI server answered on $HMI_URL after ${hmi_waited}s"
    else
        failure="HMI server did not answer on $HMI_URL within ${HMI_VALIDATE_TIMEOUT}s"
    fi
fi

if [ -z "$failure" ]; then
    rm -rf "$BOOT_DIR.old" "$BOOT_DIR.failed"
    hmi_installed && hmi_cleanup_old
    case "$pkg_id" in
        *:*|unknown) ;;  # restore/revert markers don't correspond to a stick package
        *) printf '%s\n' "$pkg_id" > "$STATE_DIR/installed-id" ;;
    esac
    rm -f "$marker"
    sync
    log "validate: SUCCESS - system healthy, rollback state cleaned up"
    exit 0
fi

log_err "validate: FAILURE - $failure"

# When TwinCAT itself failed to start, its own error-priority journal entries
# carry the actual cause (e.g. "License 'TC3 PLC' not found"). Echo them into
# our log at err priority so one `journalctl -t usb-update -p err` tells the
# whole story — the on-screen dialog has no room for them.
if [ -n "$tc_failed" ]; then
    tc_errors=$(journalctl -q -b -t TcSystemServiceUm -p err -o cat 2>/dev/null \
        | tail -n "${TC_ERR_REPORT_LINES:-10}")
    if [ -n "$tc_errors" ]; then
        log_err "validate: TwinCAT errors this boot (full log: journalctl -b -t TcSystemServiceUm):"
        while IFS= read -r line; do
            log_err "validate: TcSystemServiceUm: $line"
        done <<< "$tc_errors"
    else
        log_err "validate: no error entries from TcSystemServiceUm this boot (see journalctl -b -t TcSystemServiceUm)"
    fi
fi

revert_available() {
    [ -d "$BOOT_DIR.old" ] || hmi_old_present
}

if [ "${PROMPT_REVERT_ON_FAILURE:-0}" = "1" ] && revert_available; then
    choice=$("$(dirname "$0")/prompt.sh" \
        "Update failed to start. Revert and restart?" \
        "Revert")
    if [ "$choice" = "yes" ]; then
        if [ -d "$BOOT_DIR.old" ]; then
            rm -rf "$BOOT_DIR.failed"
            mv "$BOOT_DIR" "$BOOT_DIR.failed"
            mv "$BOOT_DIR.old" "$BOOT_DIR"
        fi
        hmi_revert
        printf 'revert:after-failed-update\n' > "$marker"
        rm -f "$STATE_DIR/installed-id"
        sync
        log "validate: reverted to previous state (failed version kept at .failed), rebooting to load it"
        ${REBOOT_CMD:-systemctl reboot}
        exit 0
    fi
    log_warn "validate: operator declined revert, leaving failed state in place"
fi

log_warn "validate: rollback state kept (.old) - to roll back manually: swap it into place and reboot."
"$(dirname "$0")/prompt.sh" --notify \
    "Update failed to start. Contact service." || true
exit 1
