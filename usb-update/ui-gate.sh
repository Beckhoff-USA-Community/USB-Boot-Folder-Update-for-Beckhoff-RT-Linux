#!/bin/bash
# Hold the HMI browser (TF1200 UI Client) back until the boot-time update
# check has finished asking the operator. install.sh rewrites the sway exec
# line that starts the client to go through this script; the original command
# line is exec'd unchanged once the gate opens, so with no stick present the
# only visible effect is the client appearing a few seconds later.
#
# usb-update-run.sh touches UI_RELEASE_FILE the moment the operator has made
# a selection (or there was nothing to ask). /run is a tmpfs, so a marker can
# never leak into the next boot. The wait is bounded on every path: if the
# service is disabled, missing, or wedged, the client starts anyway once
# UI_GATE_TIMEOUT is up.
set -u
. "$(dirname "$0")/common.sh"

[ $# -ge 1 ] || die "usage: ui-gate.sh <ui-client-command> [args...]"

# Empty/unset = auto: stick enumeration poll + dialog timeout + slack for the
# service race and the second dialog on the restore path.
gate_timeout="${UI_GATE_TIMEOUT:-}"
[ -n "$gate_timeout" ] || gate_timeout=$(( ${USB_WAIT_SECS:-10} + ${PROMPT_TIMEOUT:-60} + 60 ))

if systemctl is-enabled --quiet usb-update.service 2>/dev/null; then
    waited=0
    while [ ! -e "$UI_RELEASE_FILE" ]; do
        if [ "$waited" -ge "$gate_timeout" ]; then
            log_warn "ui-gate: not released after ${gate_timeout}s, starting the UI client anyway"
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    [ -e "$UI_RELEASE_FILE" ] && log "ui-gate: released after ${waited}s, starting the UI client"
else
    log "ui-gate: usb-update.service not enabled, starting the UI client immediately"
fi

exec "$@"
