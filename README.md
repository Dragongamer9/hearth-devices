# Hearth OS on the Oukitel RT8

Native Hearth OS for the Oukitel RT8 rugged tablet, replacing Android. The
port runs Hearth's Debian ARM64 userspace on **Halium**: Android's vendor
drivers stay underneath (GPU, Wi-Fi, audio, modem), reached through libhybris,
the same approach Droidian and Ubuntu Touch use.

**Status: Stage 1 — kernel and boot images. Nothing here has been booted yet.**

## The hardware

From the stock `OUKITEL_RT8_EEA_V14_20260828` firmware:

| | |
|---|---|
| SoC | MediaTek Helio G99 (MT8781 tablet variant of MT6789) |
| Stock kernel | GKI `5.10.233-android12-9`, clang r416183b |
| Stock Android | 14 (vendor), Halium version 14 |
| Boot layout | boot + vendor_boot, both header v4, 64 MiB each, no init_boot |
| Display | 1200×1920 DSI: BOE ICNL9551R (60/90 Hz) or Hongxun HX83102 (90 Hz) |
| Touch | Focaltech or Chipone TDDI (I²C) |
| Charging | SC89601D + MT6375 sub-PMIC, AW35615 USB-C PD |
| Audio | MT6366 codec + Awinic AW883xx amp |
| Other | ST21NFC NFC |

## Why it's built on the Volla Tablet port

The Volla Tablet ("mimir") uses the same SoC and ships Ubuntu Touch via
Halium. Its boot layout matches the RT8 exactly: same load addresses, same
kernel command line, same 64 MiB partitions, same compiler. Its kernel tree
already has drivers for the RT8's touch, charger, amp, NFC and MT6375 parts.

Its `wb,drm_lcm` panel driver reads timings and init commands from the
device tree and can take over a panel the bootloader already turned on. That
means the RT8's three panels need DT data, not new C drivers.

## Layout

```
deviceinfo                 port definition for halium-generic-adaptation-build-tools
kernel/rt8.config          RT8 kernel fragment on top of the Volla configs
dts/rt8-base.dts           stock RT8 DTB, decompiled (recompiles byte-identical)
dts/rt8-overlay.dts        stock RT8 dtbo, decompiled (recompiles byte-identical)
vendor-ramdisk-overlay/    kernel modules loaded from vendor_boot
tools/bootimg.py           boot/vendor_boot/dtbo pack + unpack (verified against stock)
tools/extract-stock.sh     pull reference pieces out of an Oukitel firmware zip
build.sh                   build boot images (Ubuntu 22.04 or CI)
flash.sh                   flash over fastboot
```

No Oukitel binaries are committed. `stock/` is git-ignored and only holds
local reference copies made by `tools/extract-stock.sh`.

## Building

CI builds on every push to `devices/rt8/` (see
`.github/workflows/rt8-port.yml`) and uploads `boot.img`, `vendor_boot.img`
and `dtbo.img` as an artifact. Locally, on Ubuntu 22.04:

```bash
cd devices/rt8
./build.sh
```

The build fetches the AOSP clang toolchain and the Volla kernel, so the first
run needs a few GB and some time.

## Before flashing anything

1. Back up every partition with mtkclient (`python mtk.py rl --skip=userdata ~/rt8-backup/`).
   That backup is the only way back to Android.
2. Find out which panel your unit has (see Stage 2).

## Stages

1. **Kernel + boot images** (this stage). Builds, fits the partitions.
2. **First boot to a shell.** Flash `./flash.sh boot`, reach the Halium
   initramfs over USB (telnet on 192.168.2.15). Needs the panel identified
   and its DT node switched to `wb,drm_lcm` with the recovered timings.
3. **Hearth rootfs.** Debian ARM64 (Peppermint base) with Halium/libhybris
   packages, Hearth's Rust/Tauri app and Mantel. Flash system (Halium 14 GSI)
   from fastbootd and the rootfs to userdata.
4. **Hardware bring-up.** Display through hwcomposer, touch, Wi-Fi, audio,
   charging, suspend, controllers.

## Recovered panel timings

From the stock panel modules (`tools/extract-stock.sh` writes these to `stock/panels.txt`):

| Panel | Mode | Clock (kHz) | H (active/sync start/end/total) | V |
|---|---|---|---|---|
| BOE ICNL9551R (OQ) | 60 Hz | 275670 | 1200/1250/1270/1306 | 1920/3500/3506/3518 |
| BOE ICNL9551R (OQ) | 90 Hz | 276101 | 1200/1250/1270/1306 | 1920/2331/2337/2349 |
| BOE ICNL9551R (Huajiacai) | 60 Hz | 306797 | 1200/1360/1364/1520 | 1920/3328/3332/3364 |
| BOE ICNL9551R (Huajiacai) | 90 Hz | 306979 | 1200/1360/1364/1520 | 1920/2208/2212/2244 |
| Hongxun HX83102 | 90 Hz | 275616 | 1200/1260/1280/1320 | 1920/2300/2308/2320 |
