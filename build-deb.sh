#!/bin/bash
# Build the usb-update Debian package. Needs only dpkg-deb (part of dpkg, so
# present on every Debian-based system including Beckhoff RT Linux itself):
#
#   ./build-deb.sh            # version from the VERSION file
#   ./build-deb.sh 1.2.3      # explicit version override
#
# Output: dist/usb-update_<version>_all.deb
set -eu
repo="$(cd "$(dirname "$0")" && pwd)"
ver="${1:-$(tr -d '[:space:]' < "$repo/VERSION")}"

# Stage into a fresh temp tree (never the checkout itself): file modes and
# ownership are set explicitly here, so a Windows/NTFS checkout builds the
# same package as a native Linux one.
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
chmod 0755 "$stage"   # mktemp defaults to 0700, which would end up on ./ in the archive

install -d -m 0755 "$stage/usr/lib/usb-update" "$stage/etc/usb-update" \
                   "$stage/usr/lib/systemd/system"
install -m 0755 "$repo"/usb-update/*.sh "$stage/usr/lib/usb-update/"
install -m 0644 "$repo/usb-update/usb-update.conf" "$stage/etc/usb-update/"
install -m 0644 "$repo"/usb-update/*.service "$stage/usr/lib/systemd/system/"

install -d -m 0755 "$stage/usr/share/man/man8"
sed "s/__VERSION__/$ver/" "$repo/man/usb-update.8" > "$stage/usr/share/man/man8/usb-update.8"
gzip -9n "$stage/usr/share/man/man8/usb-update.8"
chmod 0644 "$stage/usr/share/man/man8/usb-update.8.gz"

# A CRLF in a shell script or unit file breaks it on the device — refuse to
# package one (defense in depth on top of .gitattributes).
if crlf=$(grep -rlI $'\r' "$stage"); then
    printf '%s\n' "$crlf" >&2
    echo "ERROR: CRLF line endings in the staged files above; fix and rebuild." >&2
    exit 1
fi

install -d -m 0755 "$stage/DEBIAN"
sed "s/__VERSION__/$ver/" "$repo/deb/control.in" > "$stage/DEBIAN/control"
install -m 0644 "$repo/deb/conffiles" "$stage/DEBIAN/"
install -m 0755 "$repo"/deb/{postinst,prerm,postrm} "$stage/DEBIAN/"

mkdir -p "$repo/dist"
dpkg-deb --build --root-owner-group "$stage" "$repo/dist/usb-update_${ver}_all.deb"
