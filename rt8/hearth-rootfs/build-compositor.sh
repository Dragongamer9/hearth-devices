#!/usr/bin/env bash
# Build the RT8 display stack for Debian 13 (Hearth OS): the hwcomposer-enabled
# wlroots (Droidian's fork) and labwc, both patched (rt8/mantel/patches), into
# /opt so nothing system-wide is touched. Stock labwc on the Hearth image has
# no hwcomposer backend and can't drive the panel; this is what does.
#
#   build-compositor.sh <trixie debs dir> <droidian.gpg> <out dir>
#
# Runs inside debian:trixie on arm64 (so it links against glibc 2.41 like the
# Hearth image). Writes <out>/opt.tar.zst (/opt/wlroots-hearth + /opt/labwc)
# and <out>/report.txt.
set -uo pipefail
DEBS=$(realpath "$1"); KEY=$(realpath "$2"); OUT=$(realpath -m "$3")
HERE=$(cd "$(dirname "$0")" && pwd)
RT8=$(cd "$HERE/.." && pwd)
PATCHES="$RT8/mantel/patches"
mkdir -p "$OUT" /src
REPORT="$OUT/report.txt"; : > "$REPORT"
say() { echo "$*" | tee -a "$REPORT"; }
export DEBIAN_FRONTEND=noninteractive

WLR_REV=e7f6be5105b009a025b033ab696c34b287011156   # droidian/wlroots feature/next/backport-0.18
PREFIX_WLR=/opt/wlroots-hearth
PREFIX_LABWC=/opt/labwc

# --- apt sources: our trixie rebuilds, plus Droidian for sources + arch-indep.
apt-get update -q
apt-get install -y -q --no-install-recommends ca-certificates gnupg git meson ninja-build \
	build-essential pkg-config devscripts equivs quilt >/dev/null
cp "$KEY" /etc/apt/trusted.gpg.d/droidian.gpg
cat > /etc/apt/sources.list.d/droidian.sources <<'EOF'
Types: deb deb-src
URIs: http://releases.droidian.org/snapshots/current/
Suites: rolling
Components: main
Signed-By: /etc/apt/trusted.gpg.d/droidian.gpg
EOF
printf 'Package: *\nPin: origin releases.droidian.org\nPin-Priority: 100\n' > /etc/apt/preferences.d/droidian-low
mkdir -p /localrepo && cp "$DEBS"/*.deb /localrepo/ 2>/dev/null
rm -f /localrepo/*-dbgsym_*.deb
(cd /localrepo && dpkg-scanpackages . > Packages 2>/dev/null)
echo "deb [trusted=yes] file:/localrepo ./" > /etc/apt/sources.list.d/local.list
apt-get update -q 2>&1 | tail -3

# Our trixie libhybris (+ -dev) must satisfy the build, not Droidian's 2.43 one.
apt-get install -y -q --no-install-recommends \
	libhybris-dev libhybris-common-dev libandroid-properties-dev 2>&1 | tail -3
say "== libhybris: $(dpkg-query -W -f '${Version}' libhybris-dev 2>/dev/null)"

# --- libdroid for trixie (Droidian's wlroots backend helper; its 2.43 binary
#     won't run on the image, so rebuild it here).
stage_libdroid() {
	cd /src && rm -rf libdroid && mkdir libdroid && cd libdroid
	if apt-get source -q --only-source libdroid >/dev/null 2>&1; then :
	elif git clone -q https://github.com/droidian/libdroid libdroid-git 2>/dev/null; then :
	else say "libdroid: FAIL no source"; return 1; fi
	d=$(find . -mindepth 1 -maxdepth 1 -type d | head -1); cd "$d"
	[ -f debian/changelog ] || { DEBEMAIL="Dragongamer9 <game305.cl@gmail.com>" \
		dch --create --package libdroid -v "0~deb13" -D trixie "Rebuilt for Debian 13." >/dev/null 2>&1; }
	mk-build-deps -i -r -t 'apt-get -y -q --no-install-recommends' debian/control > /tmp/bd.log 2>&1 \
		|| { say "libdroid: FAIL build-deps: $(tail -5 /tmp/bd.log | tr '\n' ' ')"; return 1; }
	dpkg-buildpackage -b -uc -us -j"$(nproc)" > /tmp/lb.log 2>&1 \
		|| { say "libdroid: FAIL build: $(tail -12 /tmp/lb.log | tr '\n' ' ' | cut -c1-500)"; return 1; }
	cp ../*.deb "$OUT/" 2>/dev/null
	apt-get install -y -q ../libdroid*.deb 2>&1 | tail -2
	say "libdroid: OK $(cd .. && ls libdroid*.deb | tr '\n' ' ')"
}
stage_libdroid || say "== libdroid stage failed; wlroots droidian-extensions may not build"

# --- wlroots (Droidian fork) with hwcomposer + android renderer.
apt-get install -y -q --no-install-recommends hwdata libseat-dev libsystemd-dev libcap-dev \
	libdisplay-info-dev libliftoff-dev libdrm-dev libgbm-dev libegl-dev libgles2-mesa-dev \
	libinput-dev libpixman-1-dev libpng-dev libwayland-dev wayland-protocols libxkbcommon-dev \
	libxml2-dev libcairo2-dev libpango1.0-dev libglib2.0-dev librsvg2-dev gettext 2>&1 | tail -3

cd /src
[ -d wlroots ] || git clone -q https://github.com/droidian/wlroots
cd wlroots && git checkout -q -f "$WLR_REV"
for p in wlroots-0001-scene-render-for-output wlroots-0002-android-one-egl-surface-per-output \
         wlroots-0003-scene-handle-damage-in-buffer-coords; do
	git apply "$PATCHES/$p.patch" && say "applied $p" || say "PATCH FAIL $p"
done
if meson setup --wipe build --prefix="$PREFIX_WLR" -Dbackends=hwcomposer,drm,libinput \
	-Drenderers=gles2,android -Dallocators=gbm -Dxwayland=disabled -Dexamples=false \
	-Ddroidian-extensions=true -Dsession=enabled > /tmp/wm.log 2>&1 && ninja -C build install >> /tmp/wm.log 2>&1; then
	say "wlroots: OK"
else
	say "wlroots: FAIL: $(grep -iE 'error|not found|meson.build|undefined' /tmp/wm.log | tail -15 | tr '\n' ' ' | cut -c1-900)"
fi

# --- labwc against that wlroots.
cd /src
[ -d labwc ] || git clone -q https://github.com/labwc/labwc
cd labwc && git checkout -q -f 0.7.4
for p in labwc-0001-droidian-wlroots-0.18-backports labwc-0002-hearth-initial-output-transform \
         labwc-0003-xdg-initial-configure labwc-0004-xdg-new-toplevel; do
	git apply "$PATCHES/$p.patch" && say "applied $p" || say "PATCH FAIL $p"
done
apt-get install -y -q --no-install-recommends libglib2.0-dev foot >/dev/null 2>&1 || true
if PKG_CONFIG_PATH="$PREFIX_WLR/lib/aarch64-linux-gnu/pkgconfig:$PREFIX_WLR/lib/pkgconfig" \
	meson setup --wipe build --prefix="$PREFIX_LABWC" -Dxwayland=disabled -Dman-pages=disabled \
	-Dc_link_args="-Wl,-rpath,$PREFIX_WLR/lib/aarch64-linux-gnu:$PREFIX_WLR/lib" > /tmp/lm.log 2>&1 \
	&& ninja -C build install >> /tmp/lm.log 2>&1; then
	say "labwc: OK -> $(ldd $PREFIX_LABWC/bin/labwc 2>/dev/null | grep wlroots | tr -s ' ')"
else
	say "labwc: FAIL: $(grep -iE 'error|not found|undefined|meson.build' /tmp/lm.log | tail -15 | tr '\n' ' ' | cut -c1-900)"
fi

# --- package /opt for the rootfs build.
if [ -x "$PREFIX_LABWC/bin/labwc" ] && [ -d "$PREFIX_WLR" ]; then
	tar -C / -cf - opt/wlroots-hearth opt/labwc | zstd -T0 -10 -q -o "$OUT/opt.tar.zst"
	say "== packaged: $(ls -lh "$OUT/opt.tar.zst" | awk '{print $5}')"
else
	say "== NOT packaged: labwc or wlroots missing"
fi
echo "== glibc: $(dpkg-query -W -f '${Version}' libc6)" | tee -a "$REPORT"
cat "$REPORT"
