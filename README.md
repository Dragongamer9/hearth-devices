# hearth-devices

Ports of [Hearth OS](https://github.com/Dragongamer9/hearth-os) to Android
phones and tablets, replacing Android completely. Each device lives in its own
folder and has its own CI workflow.

Hearth runs on these devices through **Halium**: Android's vendor drivers
(GPU, Wi-Fi, audio, modem) stay underneath, reached from Hearth's Debian ARM64
userspace through libhybris — the approach Droidian and Ubuntu Touch use.

| Device | Folder | SoC | Status |
|---|---|---|---|
| Oukitel RT8 | [`rt8/`](rt8/) | MediaTek Helio G99 (MT8781) | Kernel and boot images build; not booted yet |

Each device folder has its own README with the hardware, how it's built, and
what's left.

No vendor firmware is committed here. Device trees are kept as source and
stock binaries are extracted locally into git-ignored folders.
