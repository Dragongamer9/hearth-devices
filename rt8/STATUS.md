# RT8 port status (November 2026)

Tested with the Ubuntu Touch 24.04 image on slot B, flashed with mtkclient.

## Working
- Our kernel boots; USB networking (10.15.19.82) and SSH as root.
- Charging while our build is running (slowly).
- The Android container stays RUNNING with about 60 vendor services. This needed the rc overrides
  (vold, 64-bit-only boringssl self tests), all APEXes mounted and VNDK v31 from stock system_ext_a.
- Touch: chipone-tddi over SPI (patches 0008/0009) gives the chipone-tddi and chipone-tddi,pen devices.
- GPU: /dev/mali0 (fhctl + gpufreq + mali_kbase_mt6789); Mali-G57 MC2, GLES 3.2 r32p1.
- Modem ccmni interfaces; 206 kernel modules copied for the container.
- Display and the Ubuntu Touch UI (2026-11-08): Lomiri runs on the 1200x1920 panel, touch works
  and the first-run wizard completes. What it took:
  - apexd-bootstrap activates the vendor's VNDK v31 APEX (vndk-apex: overlay of stock
    system_ext/apex onto system/apex, apexd.rc without reboot_on_failure), so services started
    early get a full linkerconfig;
  - lightdm.service drop-in hides hwcomposer.mtk_common.so from the compositor, so it uses the
    HIDL composer instead of loading the HAL in-process and holding DRM master;
  - vndservicemanager disabled through an rc override: without SELinux it aborts in
    Access::Access(), and its onrestart lines restarted main/hal/early_hal (allocator and
    composer) every few seconds, which dropped the session;
  - userdata needs the ext4 `encrypt` feature (`tune2fs -O encrypt`) for fscrypt status;
  - the clock must be right: with the RTC on an old date, PAM refuses the autologin
    ("password changed in future").

- Wi-Fi (2026-11-08): wlan_drv_gen4m_6789 loads; hearth-wifi-on writes 1 to /dev/wmtWifi after
  wmt_launcher is up, which creates wlan0 (plus ap0, wlan1, p2p0). NetworkManager is limited to
  wlan0 (it picked ap0 and the association failed). Connects, gets an address, browses.

## Not working yet
### Battery reading at boot
- The bootloader showed its low-battery screen with the battery at 47%; a second power-on
  booted normally. MTK_FG_NVRAM (fuel gauge calibration) fails to open in the container.

### Smaller issues
- pulseaudio aborts: libsndcardparser.so missing, 32-bit awinic.audio.effect.so.
- mediametrics/mediaserver32 need libstatspull.so.
- Pen device ignored by libinput (no resolution).
- Composer warns about plane alpha / pixel blend mode properties (-22).

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
- The first attempt to boot slot A hung on the logo. The tablet's boot1 preloader was from 2026-03-17
  and crashed the 2026-08-28 LK (watchdog reset in LK, 7 failed tries, then fallback to slot B).
- boot2 already held the August preloader. `tools/build-preloader.py` rebuilt boot1 from the package
  .bin; its output matched boot2 byte for byte. boot1 was written, read back and verified, then
  slot A was set again. The original boot1/boot2 dumps are in ~/Downloads/rt8-restore.
- Before switching back to slot B: slot B's LK and firmware are still from March and would crash
  under the August preloader, so write the August firmware to slot B first with
  `tools/firmware-to-slot.sh <fw dir> b <work dir>`. Our boot_b and vendor_boot_b stay as they are.
- Then reinstall the test userspace. The rootfs lives on userdata as /data/ubuntu.img (CI artifact
  hearth-rt8-testimage, ubuntu.img.gz). Android's factory reset left userdata as Android's own f2fs.
