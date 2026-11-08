#!/bin/sh
# Hearth RT8 (Droidian): build labwc 0.7.4 against a patched copy of Droidian's
# hwcomposer-enabled wlroots, both in /opt (nothing system-wide is replaced, so
# phosh/phoc keep using the stock library).
#
# Droidian's wlroots only gives the android renderer the output's native window
# when a render pass is begun "for output". phoc does that itself; wlr_scene
# (which labwc uses) and the empty-buffer swapchain test did not, so labwc got
# 'No native window set' and crashed. patches/wlroots-0001 fixes both places.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
WLR_REV=e7f6be5105b009a025b033ab696c34b287011156   # droidian/wlroots feature/next/backport-0.18
PREFIX_WLR=/opt/wlroots-hearth
PREFIX_LABWC=/opt/labwc
SRC=/root/hearth-src
mkdir -p "$SRC"

apt-get install -y --no-remove git meson ninja-build gcc pkg-config hwdata \
	libdroid-dev libhybris-dev libseat-dev libsystemd-dev libcap-dev libdisplay-info-dev \
	libliftoff-dev libdrm-dev libgbm-dev libegl-dev libgles2-mesa-dev libinput-dev \
	libpixman-1-dev libpng-dev libwayland-dev wayland-protocols libxkbcommon-dev \
	libxml2-dev libcairo2-dev libpango1.0-dev libglib2.0-dev librsvg2-dev gettext foot

cd "$SRC"
[ -d wlroots ] || git clone -q https://github.com/droidian/wlroots
cd wlroots
git checkout -q -f "$WLR_REV"
git apply "$HERE/patches/wlroots-0001-scene-render-for-output.patch"
meson setup --wipe build --prefix="$PREFIX_WLR" -Dbackends=hwcomposer,libinput \
	-Drenderers=gles2,android -Dallocators=gbm -Dxwayland=disabled -Dexamples=false \
	-Ddroidian-extensions=true -Dsession=enabled
ninja -C build install

cd "$SRC"
[ -d labwc ] || git clone -q https://github.com/labwc/labwc
cd labwc
git checkout -q -f 0.7.4
git apply "$HERE/patches/labwc-0001-droidian-wlroots-0.18-backports.patch"
PKG_CONFIG_PATH="$PREFIX_WLR/lib/aarch64-linux-gnu/pkgconfig:$PREFIX_WLR/lib/pkgconfig" \
	meson setup --wipe build --prefix="$PREFIX_LABWC" -Dxwayland=disabled -Dman-pages=disabled \
	-Dc_link_args="-Wl,-rpath,$PREFIX_WLR/lib/aarch64-linux-gnu:$PREFIX_WLR/lib"
ninja -C build install
echo "built: $(ldd $PREFIX_LABWC/bin/labwc | grep wlroots)"
