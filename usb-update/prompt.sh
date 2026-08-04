#!/bin/bash
# Show a swaynag dialog over the TF1200 session and print the operator's choice.
#
# Usage:
#   prompt.sh "<message>" "<yes-button-label>"   -> prints "yes" or "skip"
#   prompt.sh --notify "<message>"               -> informational, OK button only
#
# Timeout (PROMPT_TIMEOUT) defaults to skip: swaynag has no timeout of its own,
# so we launch it, poll for a choice file, and kill it when time is up. An
# unattended power cycle can therefore never hang the machine here.
set -u
. "$(dirname "$0")/common.sh"

notify=0
if [ "${1:-}" = "--notify" ]; then
    notify=1
    shift
fi
# NOTE: swaynag renders the message as a single line and reserves no space for
# the buttons it anchors at the right edge — embedded newlines show up as a
# glyph, they do not wrap. So messages must be kept SHORT enough to end before
# the button block; tune PROMPT_FONT_SIZE if they still collide.
message="${1:?usage: prompt.sh [--notify] <message> [yes-label]}"
yes_label="${2:-Update}"

# The UI session is not configured anywhere: whichever /run/user/<uid>/
# runtime dir contains a Wayland socket IS the UI session, and the socket's
# path yields both the user and the WAYLAND_DISPLAY name. The -S test skips
# the wayland-*.lock files sitting next to the socket. sway is started from
# the UI user's .bashrc after getty autologin, so it races this boot-time
# script — detection doubles as the wait for the session.
WAYLAND_WAIT_SECS=30
find_ui_sock() {
    local s
    for s in /run/user/*/wayland-*; do
        [ -S "$s" ] && { printf '%s\n' "$s"; return 0; }
    done
    return 1
}
waited=0
until sock=$(find_ui_sock); do
    if [ "$waited" -ge "$WAYLAND_WAIT_SECS" ]; then
        log_warn "prompt: no Wayland socket after ${WAYLAND_WAIT_SECS}s, defaulting to skip"
        echo skip
        exit 0
    fi
    sleep 1
    waited=$((waited + 1))
done
UI_UID=${sock#/run/user/}; UI_UID=${UI_UID%%/*}
UI_USER=$(id -un "$UI_UID" 2>/dev/null || echo "#$UI_UID")
WAYLAND_SOCKET=${sock##*/}
log "prompt: UI session detected: user $UI_USER (uid $UI_UID, display $WAYLAND_SOCKET)"

mkdir -p /run/usb-update
run_dir=$(mktemp -d /run/usb-update/prompt.XXXXXX)
chown "$UI_UID" "$run_dir"
choice_file="$run_dir/choice"
cleanup() { rm -rf "$run_dir"; }
trap cleanup EXIT

nag_env=(env "XDG_RUNTIME_DIR=/run/user/$UI_UID" "WAYLAND_DISPLAY=$WAYLAND_SOCKET")
if [ "$notify" = 1 ]; then
    sudo -u "$UI_USER" "${nag_env[@]}" \
        swaynag "${SWAYNAG_ARGS[@]}" -m "$message" \
        -Z "OK" "touch '$choice_file'" &
    timeout=20
else
    sudo -u "$UI_USER" "${nag_env[@]}" \
        swaynag "${SWAYNAG_ARGS[@]}" -m "$message" \
        -Z "$yes_label" "echo yes > '$choice_file'" \
        -Z "Skip" "echo skip > '$choice_file'" &
    timeout=$PROMPT_TIMEOUT
fi
nag_pid=$!

waited=0
while [ "$waited" -lt "$timeout" ]; do
    [ -e "$choice_file" ] && break
    kill -0 "$nag_pid" 2>/dev/null || break
    sleep 1
    waited=$((waited + 1))
done
# Note whether swaynag was still up when the wait ended: still up + no choice
# file means the operator never answered (timeout); gone + no choice file means
# the dialog was closed/dismissed without picking a button.
nag_alive=0
kill -0 "$nag_pid" 2>/dev/null && nag_alive=1
kill "$nag_pid" 2>/dev/null
wait "$nag_pid" 2>/dev/null

if [ "$notify" = 1 ]; then
    if [ -e "$choice_file" ]; then
        log "prompt: notice acknowledged by operator (message: $message)"
    else
        log "prompt: notice shown, not acknowledged (message: $message)"
    fi
    exit 0
fi

if [ -e "$choice_file" ]; then
    choice=$(cat "$choice_file" 2>/dev/null)
    [ "$choice" = "yes" ] || choice=skip
    log "prompt: operator chose '$choice' (message: $message)"
elif [ "$nag_alive" = 1 ]; then
    choice=skip
    log_warn "prompt: TIMEOUT - no operator response within ${timeout}s, defaulting to skip (message: $message)"
else
    choice=skip
    log "prompt: dialog closed without a choice, defaulting to skip (message: $message)"
fi
echo "$choice"
