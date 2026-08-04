#!/bin/bash
# Back up the current Boot folder to BACKUP_DIR/Boot.<timestamp> and — when
# the TF2000 HMI server is installed — the HMI server state to
# BACKUP_DIR/tchmisrv.<timestamp> (same timestamp = one backup set, always
# restored together). Then prune old sets down to BACKUP_RETAIN.
set -eu
. "$(dirname "$0")/common.sh"

[ -d "$BOOT_DIR" ] || die "backup: $BOOT_DIR does not exist"

mkdir -p "$BACKUP_DIR"
ts=$(date +%Y%m%d-%H%M%S)
dest="$BACKUP_DIR/Boot.$ts"

cp -a "$BOOT_DIR" "$dest.tmp"
mv "$dest.tmp" "$dest"
date -Is > "$dest.meta"

# HMI server state (config json + service/) is small (~25 MB) — always back it
# up alongside Boot so a restore can never mix application and HMI versions.
if hmi_installed; then
    hdest="$BACKUP_DIR/tchmisrv.$ts"
    json=$(hmi_config_json)
    mkdir -p "$hdest.tmp"
    [ -d "$HMI_DIR/service" ] && cp -a "$HMI_DIR/service" "$hdest.tmp/service"
    [ -f "$json" ] && cp -a "$json" "$hdest.tmp/"
    mv "$hdest.tmp" "$hdest"
    log "backup: HMI state included ($hdest)"
fi
sync

# Prune: keep the newest BACKUP_RETAIN sets (keyed by the Boot.<ts> entries;
# the tchmisrv sibling of a pruned set goes with it).
ls -1d "$BACKUP_DIR"/Boot.* 2>/dev/null | grep -v '\.meta$\|\.tmp$' | sort | head -n -"$BACKUP_RETAIN" | \
while read -r old; do
    old_ts="${old##*/Boot.}"
    log "backup: pruning backup set $old_ts"
    rm -rf "$old" "$old.meta" "$BACKUP_DIR/tchmisrv.$old_ts"
done

log "backup: created $dest"
echo "$dest"
