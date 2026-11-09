#!/usr/bin/env bash
# Build the RT8 rootfs from Hearth OS itself: the Hearth OS arm64 image plus
# the RT8 hardware layer (libhybris, the Android container, Halium wrappers)
# rebuilt for Debian 13. Runs on an arm64 host (CI: ubuntu-24.04-arm) as root.
#
#   build-hearth-rootfs.sh <hearth-peppermint-arm64-rootfs.tar.zst> <trixie debs dir> <droidian.gpg> <out dir>
#
# Writes <out>/rootfs.img (goes to /userdata/rootfs.img on the tablet, in
# place of Droidian's) and <out>/report.txt. Milestone A: it boots to SSH with
# the Android container up; the Hearth session on the panel is milestone B.
set -euo pipefail
TAR=$(realpath "$1"); DEBS=$(realpath "$2"); KEY=$(realpath "$3"); OUT=$(realpath -m "$4")
HERE=$(cd "$(dirname "$0")" && pwd)
RT8=$(cd "$HERE/.." && pwd)
WORK=$(mktemp -d); MNT="$WORK/mnt"
cleanup() {
	for m in dev/pts dev proc sys run; do umount "$MNT/$m" 2>/dev/null || true; done
	umount "$MNT" 2>/dev/null || true; rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$OUT" "$MNT"
REPORT="$OUT/report.txt"; : > "$REPORT"
say() { echo "$*" | tee -a "$REPORT"; }

# 1. An ext4 image holding the Hearth filesystem.
truncate -s 20G "$OUT/rootfs.img"
mkfs.ext4 -q -L hearth-rt8 -O ^metadata_csum_seed "$OUT/rootfs.img"
mount -o loop "$OUT/rootfs.img" "$MNT"
zstd -dc "$TAR" | tar -x -C "$MNT" --numeric-owner --xattrs --xattrs-include='*'
# The image keeps /var empty (bootc); recreate it as its tmpfiles do on boot.
systemd-tmpfiles --create --root="$MNT" >/dev/null 2>&1 || true
[ -e "$MNT/var/lib/dpkg/status" ] || { mkdir -p "$MNT/var/lib"; ln -sfn /usr/lib/sysimage/dpkg "$MNT/var/lib/dpkg"; }
mkdir -p "$MNT/var/lib/apt/lists/partial" "$MNT/var/cache/apt/archives/partial" "$MNT/var/log/apt"
for m in dev dev/pts proc sys run; do mkdir -p "$MNT/$m"; mount --bind "/$m" "$MNT/$m"; done
rm -f "$MNT/etc/resolv.conf"; cp /etc/resolv.conf "$MNT/etc/resolv.conf"
say "== base: $(grep PRETTY_NAME "$MNT/usr/lib/os-release")"

# 2. Sources: our Debian 13 rebuilds first; Droidian's archive only for the
#    architecture-independent pieces (adaptation configs, quirks), pinned low.
mkdir -p "$MNT/var/cache/hearth-rt8-debs"
cp "$DEBS"/*.deb "$MNT/var/cache/hearth-rt8-debs/"
rm -f "$MNT"/var/cache/hearth-rt8-debs/*-dbgsym_*.deb
(cd "$MNT/var/cache/hearth-rt8-debs" && dpkg-scanpackages . > Packages 2>/dev/null)
echo "deb [trusted=yes] file:/var/cache/hearth-rt8-debs ./" > "$MNT/etc/apt/sources.list.d/hearth-rt8-local.list"
install -m 644 "$KEY" "$MNT/etc/apt/trusted.gpg.d/droidian.gpg"
cat > "$MNT/etc/apt/sources.list.d/droidian.sources" <<'EOF'
Types: deb
URIs: http://releases.droidian.org/snapshots/current/
Suites: rolling
Components: main
Signed-By: /etc/apt/trusted.gpg.d/droidian.gpg
EOF
cat > "$MNT/etc/apt/preferences.d/hearth-rt8" <<'EOF'
Package: *
Pin: origin releases.droidian.org
Pin-Priority: 100

Package: *
Pin: origin ""
Pin-Priority: 900
EOF
chroot "$MNT" apt-get update -q 2>&1 | tail -3 | tee -a "$REPORT"

# 3. The hardware layer, one piece at a time so one blocker doesn't hide the rest.
export DEBIAN_FRONTEND=noninteractive
inst() {
	if chroot "$MNT" apt-get install -y -q --no-install-recommends "$@" > "$WORK/apt.log" 2>&1; then
		say "ok: $*"
	else
		say "FAIL: $* -> $(grep -E '^ |^E:' "$WORK/apt.log" | grep -vE '^ +(Get|Unpacking)' | head -8 | tr '\n' ' ' | cut -c1-600)"
	fi
}
say "== hardware layer"
inst libhybris libhybris-utils libhybris-common1 libandroid-properties1 libhardware2
inst lxc-android
inst halium-wrappers
inst audiosystem-passthrough
inst adaptation-hybris-api33 adaptation-hybris-common
inst droidian-quirks-tls-padding droidian-quirks-hybris-gl droidian-quirks-writable-image droidian-quirks-systemd
inst udev-config-hybris
inst openssh-server

# Leave apt as Hearth's: the local repo and Droidian's archive were for this build.
rm -f "$MNT/etc/apt/sources.list.d/hearth-rt8-local.list" "$MNT/etc/apt/sources.list.d/droidian.sources" \
	"$MNT/etc/apt/preferences.d/hearth-rt8"
rm -rf "$MNT/var/cache/hearth-rt8-debs"
chroot "$MNT" apt-get clean
rm -f "$MNT"/etc/ssh/ssh_host_*

# 4. RT8 bits: writable root (the Halium initramfs mounts it read-only
#    without this), the boot-OK check behind the automatic fallback.
touch "$MNT/.writable_image"
echo "Hearth OS RT8 rootfs, milestone A (Hearth OS arm64 + RT8 hardware layer)" > "$MNT/etc/hearth-rt8-rootfs"
install -D -m 644 "$RT8/rootfs/files/usr/lib/systemd/system/hearth-boot-ok.service" "$MNT/usr/lib/systemd/system/hearth-boot-ok.service"
install -D -m 755 "$RT8/rootfs/files/usr/libexec/hearth/boot-ok" "$MNT/usr/libexec/hearth/boot-ok"
mkdir -p "$MNT/usr/lib/systemd/system/multi-user.target.wants"
ln -sf ../hearth-boot-ok.service "$MNT/usr/lib/systemd/system/multi-user.target.wants/hearth-boot-ok.service"
# Hearth's PC boot pieces don't apply here (no GRUB, no bootc on the tablet yet).
chroot "$MNT" systemctl disable sddm.service bootc-fetch-apply-updates.timer >/dev/null 2>&1 || true
rm -f "$MNT/etc/systemd/system/display-manager.service"

# 5. Report what milestone B (the Hearth session on the panel) has to work with.
set +e +o pipefail
{
	echo "== installed hardware layer"
	chroot "$MNT" dpkg-query -W -f '${Package} ${Version}\n' 'libhybris*' lxc-android halium-wrappers 'adaptation-*' 'droidian-quirks-*' 2>/dev/null
	echo "== Qt's OpenGL flavour (libhybris only gives GLES)"
	q=$(ls "$MNT"/usr/lib/aarch64-linux-gnu/libQt6Gui.so.6 2>/dev/null)
	[ -n "$q" ] && chroot "$MNT" ldd /usr/lib/aarch64-linux-gnu/libQt6Gui.so.6 | grep -iE 'GLESv2|libOpenGL|libGL\.' || echo "(no libQt6Gui)"
	echo "== quickshell, labwc"; ls -l "$MNT/usr/bin/quickshell" "$MNT/usr/bin/labwc" 2>&1
	echo "== android-service units"; ls "$MNT"/usr/lib/systemd/system | grep -iE 'android|lxc|halium'
	echo "== accounts"; grep -E ':[0-9]{4,5}:' "$MNT/etc/passwd" | cut -d: -f1,3
	echo "== size"; df -h "$MNT" | tail -1
} >> "$REPORT" 2>&1
set -e -o pipefail

sync
for m in dev/pts dev proc sys run; do umount "$MNT/$m"; done
umount "$MNT"
e2fsck -fy "$OUT/rootfs.img" >/dev/null || [ $? -le 1 ]
# Shrink to what's used plus 3 GB to grow into.
resize2fs -M "$OUT/rootfs.img" >/dev/null 2>&1
blocks=$(dumpe2fs -h "$OUT/rootfs.img" 2>/dev/null | awk -F: '/Block count/{gsub(/ /,"",$2); print $2}')
truncate -s $(( blocks * 4096 + 3 * 1024 * 1024 * 1024 )) "$OUT/rootfs.img"
resize2fs "$OUT/rootfs.img" >/dev/null 2>&1
say "== image: $(ls -lsh "$OUT/rootfs.img")"
cat "$REPORT"
