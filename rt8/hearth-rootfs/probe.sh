#!/usr/bin/env bash
# Probe: can Droidian's RT8 hardware layer go on top of the Hearth OS arm64
# image? Runs on an arm64 host (CI: ubuntu-24.04-arm) as root. Changes nothing
# that is kept; writes a report.
#
#   probe.sh <droidian rootfs zip> <hearth-peppermint-arm64-rootfs.tar.zst> <out dir>
#
# 1. Lists what the Droidian rootfs adds over plain Debian (its own packages,
#    apt sources and keys, glibc).
# 2. Unpacks the Hearth arm64 filesystem, adds Droidian's apt sources and asks
#    apt (simulate only) whether the hardware packages would install.
set -uo pipefail
ZIP=$(realpath "$1"); TAR=$(realpath "$2"); OUT=$(realpath -m "$3")
WORK=$(mktemp -d); D="$WORK/droidian"; H="$WORK/hearth"
mkdir -p "$OUT" "$D" "$H"
REPORT="$OUT/probe.txt"; : > "$REPORT"
say() { echo "$*" | tee -a "$REPORT"; }
cleanup() {
	for m in dev/pts dev proc sys; do umount "$H/$m" 2>/dev/null; done
	umount "$D" 2>/dev/null; rm -rf "$WORK"
}
trap cleanup EXIT

# --- Droidian side --------------------------------------------------------
unzip -q "$ZIP" -d "$WORK/zip"
IMG=$(find "$WORK/zip" -type f -name '*.img' -printf '%s %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
if file -b "$IMG" | grep -qi 'android sparse'; then simg2img "$IMG" "$WORK/r.img"; IMG="$WORK/r.img"; fi
mount -o ro,loop "$IMG" "$D" || { say "cannot mount $IMG"; exit 1; }

say "== droidian os-release"; grep -E '^(PRETTY_NAME|VERSION_CODENAME)=' "$D/etc/os-release" | tee -a "$REPORT"
say "== droidian glibc: $(chroot "$D" dpkg-query -W -f '${Version}' libc6 2>/dev/null)"
say "== droidian apt sources"
cat "$D"/etc/apt/sources.list "$D"/etc/apt/sources.list.d/*.list "$D"/etc/apt/sources.list.d/*.sources 2>/dev/null | grep -vE '^\s*(#|$)' | tee -a "$REPORT"
say "== droidian keyrings"; ls "$D"/usr/share/keyrings "$D"/etc/apt/trusted.gpg.d 2>/dev/null | tee -a "$REPORT"

# Packages Droidian adds: anything not from Debian's own archive.
chroot "$D" dpkg-query -W -f '${Package}\t${Version}\n' > "$OUT/droidian-all.txt"
chroot "$D" sh -c 'for p in $(dpkg-query -W -f "\${Package}\n"); do apt-cache policy "$p" 2>/dev/null | grep -q "droidian" && echo "$p"; done' > "$OUT/droidian-own.txt" 2>/dev/null
if [ ! -s "$OUT/droidian-own.txt" ]; then
	grep -iE 'droidian|hybris|halium|lxc-android|adaptation' "$OUT/droidian-all.txt" | cut -f1 > "$OUT/droidian-own.txt"
fi
say "== droidian's own packages ($(wc -l < "$OUT/droidian-own.txt"))"
grep -Ff "$OUT/droidian-own.txt" "$OUT/droidian-all.txt" | tee -a "$REPORT"

# --- Hearth side ----------------------------------------------------------
zstd -dc "$TAR" | tar -x -C "$H" --numeric-owner 2>/dev/null
say "== hearth os-release"; grep -E '^(PRETTY_NAME|VERSION_CODENAME)=' "$H/etc/os-release" "$H/usr/lib/os-release" 2>/dev/null | tee -a "$REPORT"
say "== hearth glibc: $(chroot "$H" dpkg-query -W -f '${Version}' libc6 2>/dev/null)"
for m in dev dev/pts proc sys; do mkdir -p "$H/$m"; mount --bind "/$m" "$H/$m"; done
rm -f "$H/etc/resolv.conf"; cp /etc/resolv.conf "$H/etc/resolv.conf"
mkdir -p "$H/etc/apt/sources.list.d" "$H/usr/share/keyrings" "$H/etc/apt/trusted.gpg.d"
for f in "$D"/etc/apt/sources.list.d/*; do
	case "$(basename "$f")" in *droidian*|*hybris*|*halium*|*adaptation*) cp "$f" "$H/etc/apt/sources.list.d/";; esac
done
cp -n "$D"/usr/share/keyrings/*droidian* "$H/usr/share/keyrings/" 2>/dev/null
cp -n "$D"/etc/apt/trusted.gpg.d/* "$H/etc/apt/trusted.gpg.d/" 2>/dev/null
say "== sources added to hearth"; ls "$H/etc/apt/sources.list.d" | tee -a "$REPORT"
chroot "$H" apt-get update 2>&1 | tail -15 | tee -a "$REPORT"

# The hardware layer: what Droidian needs to drive the RT8 through Android.
CORE="libhybris lxc-android android-service-hwcomposer halium-wrappers hybris-usb \
	pulseaudio-modules-droid-modern audiosystem-passthrough libgbinder libglibutil \
	droidian-quirks droidian-configs-hwcomposer adaptation-hybris-api33-phone"
for p in $CORE; do
	grep -qx "$p" "$OUT/droidian-own.txt" || chroot "$H" apt-cache show "$p" >/dev/null 2>&1 || CORE=${CORE/$p/}
done
say "== simulate install (core): $CORE"
chroot "$H" apt-get install -s --no-install-recommends $CORE > "$OUT/sim-core.txt" 2>&1
say "exit=$?"; grep -E '^(E:|Inst|Remv|  |The following packages have unmet)' "$OUT/sim-core.txt" | head -80 | tee -a "$REPORT"
say "== would remove or upgrade"
grep -E '^Remv|^Inst [^ ]+ \[' "$OUT/sim-core.txt" | head -40 | tee -a "$REPORT"

say "== simulate install (everything droidian adds)"
chroot "$H" apt-get install -s --no-install-recommends $(cat "$OUT/droidian-own.txt") > "$OUT/sim-all.txt" 2>&1
say "exit=$?"; grep -E '^(E:| [a-z0-9].*: Depends|Remv)' "$OUT/sim-all.txt" | head -60 | tee -a "$REPORT"
say "== done"
exit 0
