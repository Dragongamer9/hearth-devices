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

- Touch firmware (2026-11-08): the ICNL9951R (chipone-tddi, spi0.0) has no flash. At probe the
  driver's builtin firmware is empty and /vendor/firmware isn't mounted, so touch only worked
  while the bootloader's copy survived. hearth-touch-fw writes chipone_firmware.bin to
  cts_firmware/update_from_file once the vendor partition is up. Never unbind the driver: that
  crashes the kernel.

- Sound (2026-11-08): all four speakers play through the four aw883xx smart amps on i2c-8
  (0x34-0x37, chip ID 0x2049), with pulseaudio and the MediaTek HAL. The amps share one reset
  line, which the stock DT lists only on 0x34; patch 0010 lets the other three probe without it.
  With only 0x34 running, sound came from the top-right speaker alone and seemed very quiet.

- Hearth OS desktop (2026-11-09): the Hearth OS arm64 image boots to the Mantel desktop on the panel
  (boot 19). What it took:
  - the 64-bit BoringSSL APEX self-test (`boringssl_self_test_apex64`) exits 127 and its
    `reboot_on_failure` was tearing the container down; neutralised in `init.boringssl.zygote64_32.rc`
    (run only the plain 64-bit test, never the APEX ones);
  - `vndk-apex` was deleted by a systemd ordering cycle, so VNDK v31 was never staged and the
    container's bootstrap linkerconfig aborted (SANITIZER_DEFAULT_VENDOR); run it as an ExecStartPre
    of `lxc@android` instead (drop-in in the ramdisk overlay);
  - `host-apex` skipped `com.android.runtime` ("overlapping loop device") so the host had no bionic
    libc and labwc segfaulted; now falls back to an explicit `losetup`;
  - greetd was burning its start limit before the container was up; ordered After the container +
    host-apex, start limit removed;
  - the shell (quickshell) and Qt apps can't get a GPU surface from the Mali EGL ("Cannot find
    EGLConfig"); render in software (`QT_QUICK_BACKEND=software` in `mantel-shell`). GPU for Wayland
    clients is future work.
- Hearth Browser (2026-11-09): the arm64 image shipped an x86-64 Firefox (`Exec format error`);
  `hearth-os` install-firefox now picks `linux-aarch64`, and arm64 Firefox renders in software
  (it crashes on the VA-API/renderDeviceFD probe otherwise).
- App software-render, session-wide (2026-11-09): the same Mali-EGL "no GPU surface for Wayland
  clients" that killed quickshell kills every toolkit's GPU path, so `mantel-session` now exports
  `QT_QUICK_BACKEND=software`, `WEBKIT_DISABLE_COMPOSITING_MODE=1`, `WEBKIT_DISABLE_DMABUF_RENDERER=1`
  and `GSK_RENDERER=cairo` for the whole session (and `systemctl --user import-environment`s them for
  D-Bus-activated apps). Covers Qt/QML, WebKitGTK and GTK4 apps. labwc is untouched (it drives the
  panel through the hwcomposer, not these toolkits). Ships in boot.img only (ramdisk overlay).
- App-arch audit (2026-11-09): every *core* shipped app is Qt/QML or GTK (covered above) or the
  Firefox browser (fixed). The only Electron bits are `hosts/electron` (the Chromium "window", an
  alternate renderer used on Nvidia, not the RT8 default) and `hosts/linux`'s nimbus browser; both
  build arm64-native on the arm64 runner (`dist/linux-arm64-unpacked`, Electron 38 has arm64 Linux),
  so arch is fine, but if ever used on RT8 they'd need Chromium software-GL flags (`--disable-gpu`),
  which the Qt/WebKit env vars don't provide. `hearth-claude` is a manager that downloads Anthropic's
  Claude Desktop, which upstream ships x86-only — an upstream gap, not a Hearth port task.
- Sound (Hearth OS, 2026-11-09): all four speakers work through the **native ALSA** card on **PipeWire**,
  no Android HAL. The four aw883xx smart amps are native ASoC codecs (`aw883xx-aif-8-34/35/36/37`) on
  backend **I2S3** of the `mt6789-mt6366` card. Route: front-end **DL1** (`hw:0,0`) → the interconnect
  switches `I2S3_CH1 DL1_CH1` + `I2S3_CH2 DL1_CH2` → I2S3 → the amps auto-power via DAPM
  (`aw883xx_start_pa: start success` ×4). What it took (all in the boot.img ramdisk overlay; verified
  persistent across a reboot):
  - the Droidian base runs a **standalone PulseAudio** that grabs the card, and masks PipeWire's own
    pulse front-end. The Hearth shell is a **PipeWire** client (`Quickshell.Services.Pipewire`), so it
    could never see that PA sink — the on-screen volume did nothing. Fix: mask the standalone
    PulseAudio (`/etc/systemd/user/pulseaudio.{service,socket}` → /dev/null + `autospawn = no`) and run
    **pipewire-pulse** as the PulseAudio endpoint instead (its /dev/null masks removed, socket enabled);
  - `alsa-ucm-conf` must be installed (it wasn't on the lean arm64 image) or WirePlumber makes no sink;
    added in `hosts`/the peppermint `build.sh`. With it + the UCM profile below, WirePlumber builds
    `alsa_output.platform-soc_sound.HiFi__Speaker__sink`;
  - UCM speaker profile for the card (`/usr/share/alsa/ucm2/conf.d/mt6789-mt6366/`): a HiFi verb whose
    Speaker device is `hw:${CardId},0` (DL1), with the I2S3 switches as its Enable/Disable sequence;
  - a WirePlumber rule (`51-hearth-rt8-speaker.conf`) forces the sink to **S16LE** — the path is 16-bit
    and PipeWire's default S32LE came out as loud static;
  - `hearth-audio-route.service` sets the two I2S3 switches at boot (nothing connects DL1 to the amps'
    I2S otherwise; UCM also sets them per-stream, this is the belt-and-suspenders at boot).
  Note: `speaker-test` fails hwparams (its period is outside the AFE's 24–24576 range) — test with
  `aplay`/`pw-play`/a real stream. This replaces the droid-HAL / PA-14-vs-17 dead end entirely.

## Not working yet
### Some app windows can't be moved (2026-11-09)
- The Browser and Bazaar windows can't be dragged/moved on screen (other apps are fine). Compositor/
  window-management (labwc + Mantel), not audio. Not yet investigated.

### Battery reading at boot
- The bootloader showed its low-battery screen with the battery at 47%; a second power-on
  booted normally. MTK_FG_NVRAM (fuel gauge calibration) fails to open in the container.

### Smaller issues
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
