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

- Window dragging for CSD apps (2026-11-09): the Browser (Firefox) and Bazaar draw their own title
  bars (client-side decorations), which only react to a mouse, so touch couldn't drag them. `mantel-labwc`
  now injects two labwc `windowRule`s (`serverDecoration="yes"` for `hearth-browser` and
  `io.github.kolunmi.Bazaar`) into the runtime rc.xml, so labwc gives them a server-side title bar it
  will move by touch. RT8-only (in the ramdisk generator); Hearth Desktop on PCs keeps the client-drawn
  look. Verified by dragging both on the device.

## Not working yet
### Floating mouse cursor on the touch panel (2026-11-10)
- A mouse cursor shows on screen on this touch-only device (no mouse attached). Root cause found: Hearth's
  own `hearth-pad` (hearth-os `hosts/linux/desktop/shell/hearth-pad`) creates the `Hearth controller pointer`
  uinput device (EV_REL + mouse buttons) unconditionally at startup, so wlroots always sees a pointer and
  parks a cursor. Fix is to keep that cursor hidden until the stick actually moves it (or create the pointer
  lazily when a controller appears) — but `hearth-pad` is shared with PCs, so it's a careful input change,
  not an RT8-only tweak. Not yet done.

### GPU acceleration for apps / the shell (2026-11-10)
- The compositor (labwc) is GPU-accelerated through the Android Mali EGL on the hwcomposer, but Wayland
  *clients* (Qt/QML shell, GTK/WebKit apps) can't get a GPU buffer from that Android EGL, so they run on the
  CPU (`QT_QUICK_BACKEND=software`, `GSK_RENDERER=cairo`, WebKit compositing off). Two routes, both real
  projects: (A) teach labwc/wlroots the libhybris `android_wlegl` protocol (upstream wlroots lacks it);
  (B) switch the GPU to Mesa Panfrost — the clean end state but gated entirely on the kernel (see below).
- Panfrost feasibility check (2026-11-10): the **userspace is ready** — Mesa 26.1.6 with `panfrost_dri.so`,
  libgbm, Mesa EGL and Vulkan drivers are installed; if a Panfrost render node existed the Linux stack would
  come up fast. The **kernel is the blocker**: the running `5.10.198` MTK kernel has `# CONFIG_DRM_PANFROST
  is not set` and ships proprietary `mali_kbase` (`/dev/mali0`); `/dev/dri/card0` is only the MTK display
  (`14000000.dispsys`), no GPU render node. The `panfrost.ko` on disk is Debian's `7.2.12` module and can't
  load into 5.10. Even enabling the config wouldn't help: **5.10 Panfrost predates Mali-G57/Valhall support**
  (6.x material), and MediaTek's MFG GPU power-domain/clock wiring doesn't match Panfrost's DT bindings. So
  Panfrost here = backport Valhall Panfrost to the 5.10 MTK kernel (or uprev to 6.x) + rebuild the GPU DT
  power/clock nodes + drop kbase — a full kernel sub-project with real boot risk, not a driver swap. Parked.

### CPU OpenGL via Mesa llvmpipe — works, no boot risk (2026-11-10)
- Separate from the Mali-GPU routes: Mesa 26.1.6 is installed with a working **llvmpipe** (multithreaded,
  NEON/SIMD CPU OpenGL). It gives a full **GLES 3.2** context and renders on screen as a real Wayland client
  through labwc (glmark2-es2-wayland displayed; score **68** at 800×600 — build 38 FPS, shading 33, texture
  136). Pure userspace, no kernel/boot change.
- Why apps don't use it by default: two glvnd EGL ICDs are registered and `10_libhybris.json` (the Android
  Mali driver) outranks `50_mesa.json`. Forcing Mesa makes llvmpipe come up:
  `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json LIBGL_ALWAYS_SOFTWARE=1
  GALLIUM_DRIVER=llvmpipe` (+ `EGL_PLATFORM=wayland` for a client).
- **Shell now uses it (2026-11-10):** a live A/B on the device confirmed the Mantel shell (quickshell) is
  smoother on llvmpipe GL than on Qt's software raster, so `mantel-shell` drops `QT_QUICK_BACKEND=software`
  and exports the Mesa-ICD + `LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe` (RT8 overlay; shipped in
  boot.img). Kept `QSG_RENDER_LOOP=basic` (threaded loop is worth revisiting now EGL is Mesa, not libhybris).
- **Apps now use it too (2026-11-10):** a native GTK4 app (gtk4-widget-factory) tested smooth and interactive
  on llvmpipe, so `mantel-session` drops `QT_QUICK_BACKEND=software`/`GSK_RENDERER=cairo` and exports the
  Mesa-ICD + `LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe` + `GSK_RENDERER=ngl` (the old `gl` renderer is
  removed in this GTK). Native Qt and GTK4 apps now get CPU GL. WebKitGTK web *content* stays on its
  disabled-compositing/software path (GL web path untested); flatpak apps bundle their own GL and are
  unaffected; Firefox has its own engine. Browser video still won't hardware-decode (separate VA-API/CMA story).

### Camera (2026-11-10)
- No V4L2 camera capture node exists — `/dev/video0..2` are the codec blocks (`mtk-jpeg-enc`,
  `mtk-vcodec-dec`, `mtk-vcodec-enc`), not sensors. The camera is entirely behind MediaTek's ISP + the
  Android HAL. The kernel ISP drivers are loaded (`camera_isp`, `imgsensor_isp6s`, `camera_dip_isp6s`,
  `camera_fdvt_isp51`, `camera_rsc_isp60`) and the Android `camerahalserver` is running in the container, so
  the Android half is alive. A working camera means bridging that HAL out (GBinder/hwbinder → libcamera or a
  capture app) — a real project, but the hard Android side is already up.

### Hardware video decode — blocked on CMA, and browser can't use it anyway (2026-11-10)
- The whole stack is present and the decoder *opens*: `/dev/video1` (`mtk-vcodec-dec`) accepts H.264/H.265/
  VP8/VP9/MPEG-2/4 and can output plain NV12/YV12 (not just MTK tiled MM21); GStreamer 1.26 registers
  `v4l2h264dec`/`v4l2vp8dec`/`v4l2vp9dec`; ffmpeg 7.1 has the `*_v4l2m2m` wrappers; the `mtk_mm` DMA heaps
  exist. On a decode the kernel shows `16000000.vdec decoder` opening — the hardware engages.
- But every decode fails to allocate its output buffers: `vb2ops_vdec_buf_prepare dma_general_buf is err
  -22`. Root cause: **CMA is exhausted** — `CmaTotal 176 MB`, `CmaFree ~712 KB`. The Android container/
  display takes almost all of the contiguous pool at boot, so the decoder (which needs tens of MB of
  contiguous buffers) can't get memory. Fix would be enlarging the CMA pool via the kernel boot args /
  reserved-memory in the boot.img — a **boot-touching** change (owner RED FLAG: must keep the device
  startable, test carefully), not a runtime tweak.
- Even with CMA fixed, the benefit is narrow: this V4L2 decode path serves **media-player** apps
  (GStreamer/mpv), **not Firefox** — Firefox only does hardware video via VA-API, which this MediaTek stack
  doesn't expose on Linux. So it would not accelerate browser/YouTube video; it's for local/app playback
  and battery/thermals (and makes 4K/high-bitrate smooth). Parked with the GPU/camera work as a boot-risky
  project rather than a quick win.

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
