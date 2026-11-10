#!/usr/bin/env bash
# Build the RT8 rootfs from Hearth OS itself: the Hearth OS arm64 image plus
# the RT8 hardware layer (libhybris, the Android container, Halium wrappers)
# rebuilt for Debian 13. Runs on an arm64 host (CI: ubuntu-24.04-arm) as root.
#
#   build-hearth-rootfs.sh <hearth-peppermint-arm64-rootfs.tar.zst> <trixie debs dir> <droidian.gpg> <out dir> [compositor opt.tar.zst]
#
# Writes <out>/rootfs.img (goes to /userdata/rootfs.img on the tablet, in
# place of Droidian's) and <out>/report.txt. Boots the Hearth session on the
# panel when given the compositor tarball (/opt/labwc + /opt/wlroots-hearth).
set -euo pipefail
TAR=$(realpath "$1"); DEBS=$(realpath "$2"); KEY=$(realpath "$3"); OUT=$(realpath -m "$4")
COMPOSITOR="${5:-}"; [ -n "$COMPOSITOR" ] && COMPOSITOR=$(realpath "$COMPOSITOR")
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
# PulseAudio's Android-HAL card/sink/source modules. The stock Droidian build
# is linked against libpulsecore-14.2; trixie ships PulseAudio 17, so these are
# rebuilt against it (RT8 hardware layer workflow) and land in pulse-17's module
# dir. Without them PulseAudio logs "cannot open module-droid-card" and there is
# no audio sink at all. pulseaudio-config-droid carries the matching config.
inst pulseaudio-modules-droid-modern pulseaudio-config-droid
inst adaptation-hybris-api33 adaptation-hybris-common
inst droidian-quirks-tls-padding droidian-quirks-hybris-gl droidian-quirks-writable-image droidian-quirks-systemd
inst udev-config-hybris
inst openssh-server
# The session's seat and autologin. The PC image logs in through SDDM on X;
# the RT8 has no X, so greetd starts the Mantel session on the hwcomposer seat
# directly (what phosh did on Droidian). seatd gives labwc its seat.
inst greetd seatd

# Leave apt as Hearth's: the local repo and Droidian's archive were for this build.
rm -f "$MNT/etc/apt/sources.list.d/hearth-rt8-local.list" "$MNT/etc/apt/sources.list.d/droidian.sources" \
	"$MNT/etc/apt/preferences.d/hearth-rt8"
rm -rf "$MNT/var/cache/hearth-rt8-debs"
chroot "$MNT" apt-get clean
rm -f "$MNT"/etc/ssh/ssh_host_*

# 4. RT8 bits: writable root (the Halium initramfs mounts it read-only
#    without this). The boot-OK check is installed below (4c) at a path the
#    boot ramdisk's provisioning does not wipe.
touch "$MNT/.writable_image"
echo "Hearth OS RT8 rootfs (Hearth OS arm64 + RT8 hardware layer + compositor)" > "$MNT/etc/hearth-rt8-rootfs"

# 4a. The Hearth user and the session launcher (milestone B: the shell on the
#     panel). The PC installer makes the human user; the RT8 is flashed
#     straight, so make it here. uid 1000 is NOT free: the Android adaptation
#     took it for its 'system' account (uid 1000 is 'system' on Android), so
#     give Hearth its own uid above the Android range.
say "== session"
SU=hearth
if ! chroot "$MNT" id "$SU" >/dev/null 2>&1; then
	chroot "$MNT" useradd -m -u 2000 -U -s /bin/bash -d /var/home/hearth \
		-G sudo,netdev "$SU" 2>>"$REPORT" \
		|| chroot "$MNT" useradd -m -s /bin/bash "$SU" 2>>"$REPORT" || true
fi
say "session user: $SU (uid $(chroot "$MNT" id -u "$SU" 2>/dev/null))"
# The seat/render/input groups the hwcomposer session needs; add only those
# that exist in the image.
for g in video render input audio seat plugdev; do
	chroot "$MNT" getent group "$g" >/dev/null 2>&1 && chroot "$MNT" usermod -aG "$g" "$SU" 2>/dev/null || true
done
# A known first-boot password so SSH/console login works for bring-up (RT8
# only — not a device anyone ships yet). Leave it set if the image already has
# a password for the account.
echo "$SU:hearth" | chroot "$MNT" chpasswd 2>/dev/null || true
echo 'root:hearth' | chroot "$MNT" chpasswd 2>/dev/null || true
# The Mantel scripts (installed into /usr/libexec/hearth by the boot ramdisk's
# hearth-provision) look for the shell at /usr/share/hearth/shell first; the
# image keeps it under nimbus. Point one at the other so provisioning's
# mantel-shell finds it without reflashing the boot image.
if [ -d "$MNT/usr/share/nimbus/desktop/shell" ] && [ ! -e "$MNT/usr/share/hearth/shell" ]; then
	mkdir -p "$MNT/usr/share/hearth"
	ln -sfn /usr/share/nimbus/desktop/shell "$MNT/usr/share/hearth/shell"
fi
# Check the real file (not through the absolute symlink, which would resolve
# against the build host). mantel-shell needs shell.qml in the shell dir.
if [ -f "$MNT/usr/share/nimbus/desktop/shell/shell.qml" ]; then
	say "shell entry: /usr/share/nimbus/desktop/shell/shell.qml present"
else
	say "shell entry: MISSING shell.qml -> $(ls "$MNT/usr/share/nimbus/desktop/shell/" 2>&1 | head -3 | tr '\n' ' ')"
fi

# The hwcomposer compositor (patched labwc + wlroots) the panel needs. The
# provisioning scripts exec /opt/labwc/bin/labwc and /opt/quickshell/bin/
# quickshell; stock labwc on the image can't drive hwcomposer, so ship ours
# in /opt and point /opt/quickshell at the image's quickshell.
if [ -n "$COMPOSITOR" ] && [ -f "$COMPOSITOR" ]; then
	zstd -dc "$COMPOSITOR" | tar -x -C "$MNT"
	echo "/opt/wlroots-hearth/lib/aarch64-linux-gnu" > "$MNT/etc/ld.so.conf.d/hearth-wlroots.conf"
	echo "/opt/wlroots-hearth/lib" >> "$MNT/etc/ld.so.conf.d/hearth-wlroots.conf"
	chroot "$MNT" ldconfig 2>/dev/null || true
	say "compositor: $(ls -l "$MNT/opt/labwc/bin/labwc" 2>&1 | sed 's#.*/opt#/opt#')"
else
	say "compositor: NONE (panel will stay dark; session falls back and exits)"
fi
if [ -x "$MNT/usr/bin/quickshell" ] && [ ! -e "$MNT/opt/quickshell/bin/quickshell" ]; then
	mkdir -p "$MNT/opt/quickshell/bin"
	ln -sfn /usr/bin/quickshell "$MNT/opt/quickshell/bin/quickshell"
fi
# The device display setting the Mantel scripts read (provisioning also writes
# it once; this is the fallback). Landscape at 1.25, as worked out on Droidian.
mkdir -p "$MNT/etc/hearth"
[ -f "$MNT/etc/hearth/display" ] || printf 'TRANSFORM=270\nSCALE=1.25\n' > "$MNT/etc/hearth/display"
# greetd: autologin the Hearth user into the Mantel session. mantel-session
# (from provisioning) falls back to a bare labwc if its pieces are missing, so
# a blank screen still gives a cursor to debug from over SSH.
mkdir -p "$MNT/etc/greetd"
cat > "$MNT/etc/greetd/config.toml" <<'EOF'
[terminal]
vt = 1

[initial_session]
command = "/usr/libexec/hearth/mantel-session"
user = "__SESSION_USER__"

[default_session]
command = "/usr/libexec/hearth/mantel-session"
user = "__SESSION_USER__"
EOF
sed -i "s/__SESSION_USER__/$SU/g" "$MNT/etc/greetd/config.toml"
chroot "$MNT" systemctl enable seatd.service >/dev/null 2>&1 || true
chroot "$MNT" systemctl enable greetd.service >/dev/null 2>&1 || true
ln -sfn /usr/lib/systemd/system/greetd.service "$MNT/etc/systemd/system/display-manager.service"
# Reach the graphical target even though the PC image aimed at SDDM's.
chroot "$MNT" systemctl set-default graphical.target >/dev/null 2>&1 || true
# Hearth's PC boot pieces don't apply here (no GRUB, no bootc on the tablet yet).
chroot "$MNT" systemctl disable sddm.service bootc-fetch-apply-updates.timer nimbus-autologin.service >/dev/null 2>&1 || true
# display-manager.service points at greetd (set above), not SDDM.
ln -sfn /usr/lib/systemd/system/greetd.service "$MNT/etc/systemd/system/display-manager.service"

# 4b. Hearth OS is a bootc/ostree image; its ostree + bootc units expect the
#     ostree initramfs to have set up the deployment first. The tablet uses
#     Halium's initramfs, which switch_roots the flat tree, so those units run
#     with nothing to act on and fail the boot. Mask them: boot the flat tree
#     as an ordinary Debian system. (Found by hand on the first flash.)
for u in ostree-prepare-root ostree-remount ostree-finalize-staged ostree-finalize-staged-hold \
         ostree-boot-complete ostree-state-overlay@ bootc-root-setup bootc-finalize-staged \
         bootc-finalize-staged-hold bootc-fetch-apply-updates bootc-status-updated-onboot \
         bootc-sysusers-shadow-sync bootc-destructive-cleanup bootc-publish-rhsm-facts \
         systemd-firstboot; do
	ln -sfn /dev/null "$MNT/etc/systemd/system/$u.service"
done
# Persist the journal so a failed boot can be read back from the image.
mkdir -p "$MNT/var/log/journal"

# 4c. boot-ok: the boot ramdisk's fallback renames rootfs.img -> .failed after
#     two boots unless a good start clears its counter. The ramdisk wipes
#     /usr/libexec/hearth every boot, so keep boot-ok where it survives and run
#     it from graphical.target once labwc is up.
install -D -m 755 "$RT8/rootfs/files/usr/libexec/hearth/boot-ok" "$MNT/usr/libexec/hearth-rt8/boot-ok"
cat > "$MNT/usr/lib/systemd/system/hearth-boot-ok.service" <<'EOF'
[Unit]
Description=Hearth RT8: mark this start good (clears the boot-fallback counter)
After=graphical.target
Wants=graphical.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 45
ExecStart=/usr/libexec/hearth-rt8/boot-ok
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
EOF
mkdir -p "$MNT/usr/lib/systemd/system/graphical.target.wants"
ln -sfn ../hearth-boot-ok.service "$MNT/usr/lib/systemd/system/graphical.target.wants/hearth-boot-ok.service"
# Remove the earlier multi-user link/binary this build made before the move.
rm -f "$MNT/usr/lib/systemd/system/multi-user.target.wants/hearth-boot-ok.service" \
	"$MNT/usr/libexec/hearth/boot-ok"

# 5. Report what the Hearth session on the panel has to work with.
set +e +o pipefail
{
	echo "== installed hardware layer"
	chroot "$MNT" dpkg-query -W -f '${Package} ${Version}\n' 'libhybris*' lxc-android halium-wrappers 'adaptation-*' 'droidian-quirks-*' 2>/dev/null
	echo "== Qt's OpenGL flavour (libhybris only gives GLES)"
	q=$(ls "$MNT"/usr/lib/aarch64-linux-gnu/libQt6Gui.so.6 2>/dev/null)
	[ -n "$q" ] && chroot "$MNT" ldd /usr/lib/aarch64-linux-gnu/libQt6Gui.so.6 | grep -iE 'GLESv2|libOpenGL|libGL\.' || echo "(no libQt6Gui)"
	echo "== quickshell, labwc"; ls -l "$MNT/usr/bin/quickshell" "$MNT/usr/bin/labwc" 2>&1
	echo "== session launcher"
	echo "display-manager -> $(readlink -f "$MNT/etc/systemd/system/display-manager.service" 2>&1)"
	chroot "$MNT" systemctl is-enabled greetd.service seatd.service 2>&1 | paste -sd' '
	echo "greetd config:"; sed 's/^/  /' "$MNT/etc/greetd/config.toml"
	echo "session user: $(chroot "$MNT" id "$SU" 2>&1)"
	echo "shell link: $(ls -ld "$MNT/usr/share/hearth/shell" 2>&1 | sed 's#.*/usr/share#/usr/share#')"
	echo "default target: $(chroot "$MNT" systemctl get-default 2>&1)"
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
