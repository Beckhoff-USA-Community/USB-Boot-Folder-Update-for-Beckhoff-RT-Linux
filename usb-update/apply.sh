#!/bin/bash
# Apply an update package (mounted stick root, arg 1) to the device: the
# TwinCAT boot folder part ($PKG_TC_SUBDIR) and/or the HMI part
# ($PKG_HMI_SUBDIR). Both parts are staged on the target filesystem and
# verified BEFORE either is swapped in, so a bad copy leaves everything
# untouched. Boot.old / service.old are kept as instant-rollback sources until
# validate.sh confirms the new state is healthy.
#
# Usage: apply.sh <package-root> [package-id]
set -eu
. "$(dirname "$0")/common.sh"

# Runtime junk dropped from each packaged HMI instance. Do NOT add the SQLite
# *.db-wal/-shm sidecars — deleting those could lose the last transactions.
HMI_JUNK_GLOBS="TcHmiSrv.lock TcHmiSrv.lock.pid"

src_root="${1:?usage: apply.sh <package-root> [package-id]}"
pkg_id="${2:-}"
tc_src="$src_root/$PKG_TC_SUBDIR"
hmi_src="$src_root/$PKG_HMI_SUBDIR"
[ -d "$tc_src" ] || [ -d "$hmi_src" ] || die "apply: $src_root has neither $PKG_TC_SUBDIR nor $PKG_HMI_SUBDIR"

# --- Stage the TwinCAT boot folder part -----------------------------------
staged=""
old="$BOOT_DIR.old"
if [ -d "$tc_src" ]; then
    [ -f "$tc_src/CurrentConfig.xml" ] || die "apply: $tc_src has no CurrentConfig.xml"
    parent=$(dirname "$BOOT_DIR")
    staged="$parent/Boot.staged"

    rm -rf "$staged"
    cp -a "$tc_src" "$staged"

    # Verify the copy is byte-identical to the source (catches a yanked stick).
    diff -r "$tc_src" "$staged" >/dev/null || { rm -rf "$staged"; die "apply: Boot copy verification failed, aborting (nothing changed)"; }

    # Device state (event log, persistent variables) never comes from the stick:
    # drop anything matching the preserve globs that the package shipped (e.g. a
    # stale .bootdata from whatever machine built the stick), then carry the
    # device's own copies over.
    for glob in $PRESERVE_GLOBS; do
        ( cd "$staged" && ls -1d $glob 2>/dev/null || true ) | while read -r rel; do
            rel="${rel%/}"
            rm -rf "${staged:?}/$rel"
            log "apply: dropped device-state file shipped in package: $rel"
        done
        ( cd "$BOOT_DIR" 2>/dev/null && ls -1d $glob 2>/dev/null || true ) | while read -r rel; do
            rel="${rel%/}"
            [ -e "$BOOT_DIR/$rel" ] || continue
            mkdir -p "$staged/$(dirname "$rel")"
            rm -rf "${staged:?}/$rel"
            cp -a "$BOOT_DIR/$rel" "$staged/$rel"
            log "apply: preserved device state: $rel"
        done
    done
fi

# --- Stage the HMI part ----------------------------------------------------
hmi_staged=""
hmi_json_staged=""
if [ -d "$hmi_src" ]; then
    hmi_installed || die "apply: package has an HMI part but this device has no TF2000 HMI server"
    hmi_staged="$HMI_DIR/service.staged"
    hmi_json_staged="$HMI_DIR/TcHmiSrv.Service.Config.json.staged"
    mkdir -p "$HMI_DIR"
    rm -rf "$hmi_staged" "$hmi_json_staged"
    mkdir -p "$hmi_staged"

    instances=()
    for inst in "$hmi_src"/*/; do
        [ -d "$inst" ] || continue
        name=$(basename "$inst")
        instances+=("$name")
        cp -a "$inst" "$hmi_staged/$name"
        diff -r "$inst" "$hmi_staged/$name" >/dev/null \
            || { rm -rf "$hmi_staged" "$hmi_json_staged" "$staged"; die "apply: HMI copy verification failed for '$name', aborting (nothing changed)"; }

        # Runtime junk never installs; device-state files (HMI event history)
        # are dropped from the package and carried over from the device's
        # existing instance of the same name. Both live at the instance root.
        for glob in $HMI_JUNK_GLOBS $HMI_PRESERVE_GLOBS; do
            ( cd "$hmi_staged/$name" && ls -1d $glob 2>/dev/null || true ) | while read -r rel; do
                rel="${rel%/}"
                rm -rf "$hmi_staged/$name/${rel:?}"
                log "apply: dropped from HMI package ($name): $rel"
            done
        done
        for glob in $HMI_PRESERVE_GLOBS; do
            ( cd "$HMI_DIR/service/$name" 2>/dev/null && ls -1d $glob 2>/dev/null || true ) | while read -r rel; do
                rel="${rel%/}"
                [ -e "$HMI_DIR/service/$name/$rel" ] || continue
                rm -rf "$hmi_staged/$name/${rel:?}"
                cp -a "$HMI_DIR/service/$name/$rel" "$hmi_staged/$name/$rel"
                log "apply: preserved HMI device state ($name): $rel"
            done
        done
    done
    [ "${#instances[@]}" -gt 0 ] || { rm -rf "$hmi_staged"; die "apply: $hmi_src contains no instance folder"; }

    # The stick does not carry TcHmiSrv.Service.Config.json — generate it from
    # the instance list (all enabled).
    {
        printf '{'
        sep=""
        for name in "${instances[@]}"; do
            printf '%s"%s":{"enabled":true}' "$sep" "$name"
            sep=","
        done
        printf '}\n'
    } > "$hmi_json_staged"

    chown -R "$HMI_USER:$HMI_USER" "$hmi_staged" "$hmi_json_staged"
    log "apply: HMI part staged (${instances[*]})"
fi
sync

# From here on, the device no longer matches any validated package: drop the
# installed-id BEFORE swapping, so a failed (or power-interrupted) update can
# never make detect claim a re-inserted older stick is "already installed".
mkdir -p "$STATE_DIR"
rm -f "$STATE_DIR/installed-id"
sync

# Atomic swaps. The .old state stays until validation passes.
if [ -n "$staged" ]; then
    rm -rf "$old"
    mv "$BOOT_DIR" "$old"
    mv "$staged" "$BOOT_DIR"
    sync
    log "apply: Boot swapped (previous kept at $old)"
fi
if [ -n "$hmi_staged" ]; then
    hmi_swap "$hmi_staged" "$hmi_json_staged"
    log "apply: HMI service state swapped (previous kept at $HMI_DIR/service.old)"
fi

# Arm post-boot validation. installed-id is only written by validate.sh on success.
printf '%s\n' "${pkg_id:-unknown}" > "$STATE_DIR/pending-validation"
sync

log "apply: done, validation pending"
