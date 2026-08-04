#!/bin/bash
# Restore the newest local backup set over the current state: the Boot folder
# and, when the set includes one, the HMI server state (they were captured
# together and are restored together so application and HMI versions can never
# mix). A restore is a true point-in-time revert: it does NOT preserve current
# device state, it puts back exactly what was backed up.
set -eu
. "$(dirname "$0")/common.sh"

newest=$(ls -1d "$BACKUP_DIR"/Boot.* 2>/dev/null | grep -v '\.meta$\|\.tmp$' | sort | tail -n 1)
[ -n "$newest" ] || die "restore: no backup available in $BACKUP_DIR"
[ -f "$newest/CurrentConfig.xml" ] || die "restore: backup $newest looks incomplete"
ts="${newest##*/Boot.}"
hmi_backup="$BACKUP_DIR/tchmisrv.$ts"

parent=$(dirname "$BOOT_DIR")
staged="$parent/Boot.staged"
old="$BOOT_DIR.old"

rm -rf "$staged"
cp -a "$newest" "$staged"
diff -r "$newest" "$staged" >/dev/null || { rm -rf "$staged"; die "restore: copy verification failed, aborting (nothing changed)"; }

# Stage the HMI half of the set, if there is one and the device has the server.
hmi_staged=""
hmi_json_staged=""
if [ -d "$hmi_backup" ] && hmi_installed; then
    hmi_staged="$HMI_DIR/service.staged"
    hmi_json_staged="$HMI_DIR/TcHmiSrv.Service.Config.json.staged"
    mkdir -p "$HMI_DIR"
    rm -rf "$hmi_staged" "$hmi_json_staged"
    # The backup holds what existed at capture time; either piece may be absent
    # (e.g. backup taken before any HMI was published).
    if [ -d "$hmi_backup/service" ]; then
        cp -a "$hmi_backup/service" "$hmi_staged"
        diff -r "$hmi_backup/service" "$hmi_staged" >/dev/null \
            || { rm -rf "$staged" "$hmi_staged"; die "restore: HMI copy verification failed, aborting (nothing changed)"; }
    else
        mkdir -p "$hmi_staged"
    fi
    if [ -f "$hmi_backup/TcHmiSrv.Service.Config.json" ]; then
        cp -a "$hmi_backup/TcHmiSrv.Service.Config.json" "$hmi_json_staged"
    else
        printf '{}\n' > "$hmi_json_staged"
    fi
    chown -R "$HMI_USER:$HMI_USER" "$hmi_staged" "$hmi_json_staged"
elif [ -d "$hmi_backup" ]; then
    log_warn "restore: backup set has HMI state but this device has no TF2000 HMI server - skipping it"
fi
sync

rm -rf "$old"
mv "$BOOT_DIR" "$old"
mv "$staged" "$BOOT_DIR"
sync

if [ -n "$hmi_staged" ]; then
    hmi_swap "$hmi_staged" "$hmi_json_staged"
    log "restore: HMI state restored from set $ts"
fi

mkdir -p "$STATE_DIR"
printf 'restore:%s\n' "$(basename "$newest")" > "$STATE_DIR/pending-validation"
# A restore means the stick's package is no longer what's installed.
rm -f "$STATE_DIR/installed-id"
sync

log "restore: restored $newest (previous kept at $old), validation pending"
