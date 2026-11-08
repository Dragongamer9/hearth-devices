#!/bin/sh
# Hearth RT8 (Droidian): build Quickshell (Mantel's shell) on the device, at the
# same tag as the other Hearth images (os-bases/*/builder.sh in hearth-os).
# On the RT8 Mantel runs on phoc, Droidian's hwcomposer compositor, instead of
# labwc (labwc crashes inside libhybris when it creates its EGL window surface).
set -eu
QUICKSHELL_REF="${QUICKSHELL_REF:-v0.3.2}"
SRC=/root/hearth-src
mkdir -p "$SRC"
apt-get install -y --no-remove git cmake ninja-build meson gcc g++ pkg-config \
	qt6-base-dev qt6-base-private-dev qt6-declarative-dev qt6-declarative-private-dev \
	qt6-wayland-dev qt6-shadertools-dev qt6-svg-dev spirv-tools libcli11-dev libjemalloc-dev \
	libpipewire-0.3-dev libpam0g-dev libpolkit-agent-1-dev libpolkit-gobject-1-dev \
	libwayland-dev libdrm-dev libgbm-dev wayland-protocols \
	qml6-module-qtquick qml6-module-qtquick-layouts qml6-module-qtquick-particles \
	qml6-module-qtquick-window qml6-module-qtqml-workerscript qml6-module-qtquick-controls \
	qml6-module-qtquick-shapes qml6-module-qt5compat-graphicaleffects
for p in qt6-wayland-private-dev vulkan-headers spirv-headers; do
	apt-get install -y --no-remove "$p" || echo "quickshell: $p not available"
done

cd "$SRC"
if [ ! -d wayland-protocols ]; then
	git clone -q --depth 1 --branch 1.46 https://gitlab.freedesktop.org/wayland/wayland-protocols.git
fi
meson setup --wipe wayland-protocols/build wayland-protocols --prefix=/opt/quickshell -Dtests=false
ninja -C wayland-protocols/build install

[ -d quickshell ] || git clone -q https://github.com/quickshell-mirror/quickshell
cd quickshell
git fetch -q --tags
git checkout -q -f "$QUICKSHELL_REF"
PKG_CONFIG_PATH=/opt/quickshell/share/pkgconfig cmake -S . -B build -G Ninja \
	-DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/opt/quickshell \
	-DDISTRIBUTOR="Hearth OS (RT8 Droidian)" -DCRASH_HANDLER=OFF -DHYPRLAND=OFF -DI3=OFF
cmake --build build
cmake --install build
echo "built: $(/opt/quickshell/bin/quickshell --version 2>&1 | head -1)"
