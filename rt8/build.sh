#!/usr/bin/env bash
# Build the Hearth OS kernel + boot images for the Oukitel RT8.
#
#   ./build.sh            full build → out/boot.img, out/vendor_boot.img, out/dtbo.img
#   ./build.sh -k         kernel only
#   ./build.sh -m         open menuconfig on the merged config
#
# Runs on Ubuntu 22.04 (what CI uses); the toolchain is fetched from AOSP.
# No Oukitel binaries are needed: the device tree is built from dts/.
set -euo pipefail
cd "$(dirname "$0")"

TOOLS_REPO="https://gitlab.com/ubports/porting/community-ports/halium-generic-adaptation-build-tools.git"
WORKDIR="${WORKDIR:-workdir}"

# 0. Device tree from source.
mkdir -p dt
# MediaTek's bootloader expects the vendor_boot DTB wrapped in an Android DT
# table, exactly like stock (the wrapped result is byte-identical to stock).
dtc -q -@ -I dts -O dtb -o dt/rt8-base.dtb dts/rt8-base.dts
python3 -I tools/bootimg.py pack-dtbo dt/rt8-base.dtb -o dt/vendor.dtb
dtc -q -@ -I dts -O dtb -o dt/rt8-overlay.dtbo dts/rt8-overlay.dts
python3 -I tools/bootimg.py pack-dtbo dt/rt8-overlay.dtbo -o dt/dtbo.img

[[ -d build ]] || git clone --depth 1 "$TOOLS_REPO" build

# 1. Fetch kernel + toolchains only.
./build/build.sh -b "$WORKDIR" -c

# 2. Reset the kernel tree to the pristine Volla source. CI restores the
#    kernel tree and build output from cache, so start from a clean tree and
#    re-apply everything; only files that actually change get rebuilt.
# shellcheck source=deviceinfo disable=SC2154
source ./deviceinfo
KERNEL_DIR="$WORKDIR/downloads/$(basename "${deviceinfo_kernel_source%.git}")"
git -C "$KERNEL_DIR" checkout -q -- .
git -C "$KERNEL_DIR" clean -qfd

# 3. RT8 config fragment and Hearth kernel patches. A patch that doesn't
#    apply to the clean tree is a real error, so stop instead of skipping it.
cp kernel/rt8.config "$KERNEL_DIR/arch/arm64/configs/rt8.config"
if compgen -G "kernel/patches/*.patch" > /dev/null; then
    for p in kernel/patches/*.patch; do
        git -C "$KERNEL_DIR" apply "$PWD/$p" || { echo "patch $p does not apply" >&2; exit 1; }
        echo "applied $p"
    done
fi

# 4. Full build (clone step is skipped for repos that already exist).
./build/build.sh -b "$WORKDIR" "$@"

# 5. The Halium tools leave the flashable images in workdir/tmp/partitions/;
#    put them next to the device tarball in out/.
cp -v "$WORKDIR"/tmp/partitions/*.img out/

echo
echo "Images in out/:"
ls -lh out/
