#!/usr/bin/env bash
# Build the RT8 Hearth rootfs (milestone 1) from Droidian's generic arm64
# rootfs. Runs on an arm64 Linux host (CI: ubuntu-24.04-arm) as root.
#
#   build-rootfs.sh <droidian rootfs zip> <out dir>
#
# Writes <out>/rootfs.img (goes to /data/rootfs.img on the tablet) and
# <out>/report.txt (package versions that decide the next milestone).
# The Android side stays our own Halium 14 image (/data/android-rootfs.img),
# and the boot ramdisk installs the RT8 fixes (hearth-provision) at boot.
set -euo pipefail
set -x
ZIP=$(realpath "$1")
OUT=$(realpath -m "$2")
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
MNT="$WORK/mnt"
trap 'cleanup' EXIT
cleanup() {
	for m in dev/pts dev proc sys run; do umount "$MNT/$m" 2>/dev/null || true; done
	umount "$MNT" 2>/dev/null || true
	rm -rf "$WORK"
}
mkdir -p "$OUT" "$MNT"

# 1. Find the rootfs image in the zip (the largest ext4 image in it).
unzip -q "$ZIP" -d "$WORK/zip"
echo "== zip contents"; find "$WORK/zip" -type f -printf '%s %P\n' | sort -n | tail -15
IMG=""
while read -r f; do
	if file -b "$f" | grep -qi 'ext[234] filesystem'; then IMG="$f"; break; fi
	if file -b "$f" | grep -qi 'android sparse'; then
		simg2img "$f" "$WORK/unsparse.img" && IMG="$WORK/unsparse.img" && break
	fi
done < <(find "$WORK/zip" -type f -name '*.img' -printf '%s %p\n' | sort -rn | cut -d' ' -f2-)
[ -n "$IMG" ] || { echo "no ext4 rootfs image in $ZIP" >&2; exit 1; }
echo "== rootfs image: $IMG"
cp --sparse=always "$IMG" "$OUT/rootfs.img"
rm -rf "$WORK/zip" "$WORK/unsparse.img"

# 2. Room for what we add (and later milestones), then mount.
e2fsck -fy "$OUT/rootfs.img" || [ $? -le 1 ]
truncate -s +3G "$OUT/rootfs.img"
resize2fs "$OUT/rootfs.img"
mount -o loop "$OUT/rootfs.img" "$MNT"
for m in dev dev/pts proc sys run; do mount --bind "/$m" "$MNT/$m"; done
cp /etc/resolv.conf "$MNT/etc/resolv.conf.hearth" 2>/dev/null || true

# 3. Changes inside the rootfs.
#  - SSH from the first boot (hearth-provision installs the key-only service).
#  - The Halium initramfs remounts the rootfs read-only unless /.writable_image
#    exists; Droidian expects a writable root.
#  - Marker and the boot-OK service for the automatic fallback.
chroot "$MNT" /bin/sh -e <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive
[ -f /etc/resolv.conf.hearth ] && { cp /etc/resolv.conf /etc/resolv.conf.orig 2>/dev/null || true; cat /etc/resolv.conf.hearth > /etc/resolv.conf; }
apt-get update
dpkg -s openssh-server >/dev/null 2>&1 || apt-get install -y --no-install-recommends openssh-server
apt-get clean
if [ -f /etc/resolv.conf.orig ]; then mv /etc/resolv.conf.orig /etc/resolv.conf; fi
rm -f /etc/resolv.conf.hearth
# Host keys made here would be the same on every tablet; sshd-keygen makes
# new ones on the first boot.
rm -f /etc/ssh/ssh_host_*
exit 0
CHROOT
touch "$MNT/.writable_image"
echo "Hearth OS RT8 rootfs, milestone 1 (Droidian base)" > "$MNT/etc/hearth-rt8-rootfs"
install -D -m 644 "$HERE/files/usr/lib/systemd/system/hearth-boot-ok.service" "$MNT/usr/lib/systemd/system/hearth-boot-ok.service"
install -D -m 755 "$HERE/files/usr/libexec/hearth/boot-ok" "$MNT/usr/libexec/hearth/boot-ok"
mkdir -p "$MNT/usr/lib/systemd/system/graphical.target.wants"
ln -sf ../hearth-boot-ok.service "$MNT/usr/lib/systemd/system/graphical.target.wants/hearth-boot-ok.service"

# 4. Report: what Droidian gives us for display, sound and the Android side.
# Best effort: a missing package or file must not fail the build.
set +e +o pipefail
{
	echo "== os-release"; cat "$MNT/etc/os-release"
	echo "== packages"
	chroot "$MNT" dpkg-query -W -f '${Package} ${Version}\n' \
		'libhybris*' 'libwlroots*' 'wlroots*' phoc phosh 'labwc' 'quickshell' 'pulseaudio-modules-droid*' \
		'adaptation-*' 'lxc-android*' 'droidian-*' 'hybris-*' 'qt6-base*' 'libqt6core6*' 'libwebkit2gtk*' 2>/dev/null || true
	echo "== apt candidates"
	chroot "$MNT" apt-cache policy labwc quickshell libwlroots-0.18-dev libwlroots-0.19-dev 2>/dev/null | grep -E '^[a-z]|Candidate' || true
	echo "== wlroots libs"; ls "$MNT"/usr/lib/aarch64-linux-gnu/ | grep -iE 'wlroots|hybris' || true
	echo "== lxc config"; head -40 "$MNT/var/lib/lxc/android/config" 2>/dev/null || echo "(none)"
	echo "== size"; df -h "$MNT" | tail -1
} > "$OUT/report.txt" 2>&1
set -e -o pipefail

sync
for m in dev/pts dev proc sys run; do umount "$MNT/$m"; done
umount "$MNT"
e2fsck -fy "$OUT/rootfs.img" || [ $? -le 1 ]
echo "== done"; ls -lsh "$OUT"
