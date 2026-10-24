#!/usr/bin/env bash
# Flash a Hearth OS RT8 build over fastboot.
#
#   ./flash.sh boot      boot.img + vendor_boot.img + dtbo.img only (safe first test)
#   ./flash.sh full      also system (Halium GSI) and the Hearth rootfs
#
# The tablet must be in fastboot (adb reboot bootloader) with an unlocked
# bootloader. Keep your mtkclient backup: it is the way back to Android.
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-boot}"
OUT="${OUT:-out}"

command -v fastboot >/dev/null || { echo "install fastboot (android-tools)"; exit 1; }
fastboot devices | grep -q . || { echo "no device in fastboot mode"; exit 1; }

echo ">> disabling AVB verification (our images are unsigned)"
fastboot --disable-verity --disable-verification flash vbmeta "$OUT/vbmeta.img"

echo ">> flashing boot images"
fastboot flash boot "$OUT/boot.img"
fastboot flash vendor_boot "$OUT/vendor_boot.img"
fastboot flash dtbo "$OUT/dtbo.img"

if [[ "$MODE" == "full" ]]; then
    # system lives inside the dynamic "super" partition, so it can only be
    # written from fastbootd (userspace fastboot), not the bootloader.
    echo ">> switching to fastbootd for the Halium system image"
    fastboot reboot fastboot
    fastboot flash system "$OUT/system.img"
    # Hearth rootfs install (userdata) arrives with the rootfs build stage.
    echo "!! rootfs flashing not wired up yet — see README 'Stage 3'"
fi

echo ">> rebooting"
fastboot reboot
