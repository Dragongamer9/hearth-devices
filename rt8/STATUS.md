# RT8 port status (November 2026)

Tested with the Ubuntu Touch 24.04 image on slot B, flashed with mtkclient.

## Working
- Our kernel boots; USB networking (10.15.19.82) and SSH as root.
- Charging while our build is running (slowly).
- The Android container stays RUNNING with about 60 vendor services. This needed the rc overrides
  (vold, 64-bit-only boringssl self tests), all APEXes mounted and VNDK v31 from stock system_ext_a.
- Touch: chipone-tddi over SPI (patches 0008/0009) gives the chipone-tddi and chipone-tddi,pen devices.
- GPU: /dev/mali0 (fhctl + gpufreq + mali_kbase_mt6789).
- Modem ccmni interfaces; 206 kernel modules copied for the container.

## Not working yet
### Display (black screen)
- vendor.hwcomposer-2-3 loads /vendor/lib64/hw/hwcomposer.mtk_common.so, which fails with
  `library "libandroidicu.so" not found: needed by /system/lib64/libxml2.so in namespace (default)`.
  It then falls back to gralloc/HWC2OnFbAdapter, which lacks function 54, and exits.
- Checked and fine:
  - the container /linkerconfig (1880 lines) has a correct [vendor] section, with vndk search on
    /apex/com.android.vndk.v31/${LIB};
  - /apex/com.android.vndk.v31/lib64 inside the container has 134 files, including libxml2.so;
  - the service runs from /vendor/bin/hw and matches dir.vendor;
  - vendor services and lxc-attach share one mount namespace;
  - there are no LD_* variables.
- Next checks:
  - whether libxml2.so is in the container's [vendor] `namespace.default.link.vndk.shared_libs`;
  - linker debug with `setprop debug.ld.all dlerror,dlopen` and logcat tag `linker`.
- While hwcomposer is broken, lomiri-system-compositor opens /dev/dri/card0 itself and holds DRM
  master. That should go away once hwcomposer works.

### Wi-Fi
- wmt_loader/wmt_launcher start, but no wlan0 yet. Not investigated.

### Charging while powered off
- Overnight on the charger, the battery ran flat instead of filling. While off and plugged in, the
  tablet boots our build instead of staying in a charge-only mode.
- To charge, switch to stock Android on slot A (below).

## Slots
- The active slot lives in `misc` at offset 2048 (AOSP bootloader_control, magic 0x42414342, CRC32
  of the first 28 bytes).
- Switch with `tools/slot.py` (the same script as ~/Downloads/slot.py):
  ```
  mtk.py r misc misc.bin
  python3 slot.py misc.bin a misc_a.bin
  mtk.py w misc misc_a.bin
  ```
- Write one partition per mtkclient call. Comma lists stop after the first write on this device.
- Before the stock restore, slot A held an old Halium test boot. Slot B holds our current build.

## Stock restore (2026-11-07)
- Restored with `tools/restore-stock.sh` (every slot A partition except the preloader; userdata and
  metadata zeroed) and `tools/write-big.sh` for super, written in 1 GiB pieces at 0x57800000.
- Firmware: Oukitel P556_OQ_P10B_8781_U0_EEA_V2.1.5_S260828. Slot A is active; slot B still holds
  our build (b25).
- To return to our build later: write the saved misc.bin (slot B active) back with mtkclient.
