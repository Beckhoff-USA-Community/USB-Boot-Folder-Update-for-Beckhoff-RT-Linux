#!/bin/bash
# Gate (or un-gate) the sway exec line that launches the TF1200 UI Client, so
# the HMI browser waits for the boot-time update decision instead of racing
# the dialog. Called by the package's postinst (gate) and prerm (ungate);
# deliberately standalone — no config is read, the gate path is fixed.
#
# Both subcommands are idempotent and always exit 0: a device without a
# TF1200 sway config (headless, or HMI-less) is a warning, not an error.
set -u

GATE=/usr/lib/usb-update/ui-gate.sh
CONFIGS=(/home/*/.config/sway/config /etc/sway/config /etc/sway/config.d/*)

case "${1:-}" in
    gate)
        gated=0
        for cfg in "${CONFIGS[@]}"; do
            [ -f "$cfg" ] || continue
            grep -q 'TF1200-UI-Client' "$cfg" || continue
            if grep -q "$GATE" "$cfg"; then
                gated=1
                continue
            fi
            sed -i -E "s|^([[:space:]]*exec[[:space:]]+)(.*TF1200-UI-Client)|\\1$GATE \\2|" "$cfg"
            if grep -q "$GATE" "$cfg"; then
                echo "gated the TF1200 UI Client launch in $cfg"
                gated=1
            fi
        done
        if [ "$gated" = 0 ]; then
            echo "WARNING: no sway config launching the TF1200 UI Client found -" >&2
            echo "the update dialog will appear over an already-running HMI client." >&2
        fi
        ;;
    ungate)
        for cfg in "${CONFIGS[@]}"; do
            [ -f "$cfg" ] || continue
            if grep -q "$GATE" "$cfg"; then
                sed -i "s|$GATE ||g" "$cfg"
                echo "restored direct TF1200 UI Client launch in $cfg"
            fi
        done
        ;;
    *)
        echo "usage: $0 gate|ungate" >&2
        exit 2
        ;;
esac
exit 0
