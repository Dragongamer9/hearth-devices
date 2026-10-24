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
dtc -q -@ -I dts -O dtb -o dt/vendor.dtb dts/rt8-base.dts
dtc -q -@ -I dts -O dtb -o dt/rt8-overlay.dtbo dts/rt8-overlay.dts
python3 -I tools/bootimg.py pack-dtbo dt/rt8-overlay.dtbo -o dt/dtbo.img

[[ -d build ]] || git clone --depth 1 "$TOOLS_REPO" build

# 1. Fetch kernel + toolchains only.
./build/build.sh -b "$WORKDIR" -c

# 2. Drop the RT8 config fragment into the cloned kernel tree.
# shellcheck source=deviceinfo disable=SC2154
source ./deviceinfo
KERNEL_DIR="$WORKDIR/downloads/$(basename "${deviceinfo_kernel_source%.git}")"
cp kernel/rt8.config "$KERNEL_DIR/arch/arm64/configs/rt8.config"

# 3. Apply any Hearth kernel patches (idempotent).
if compgen -G "kernel/patches/*.patch" > /dev/null; then
    for p in kernel/patches/*.patch; do
        if git -C "$KERNEL_DIR" apply --check "$PWD/$p" 2>/dev/null; then
            git -C "$KERNEL_DIR" apply "$PWD/$p" && echo "applied $p"
        else
            echo "skip $p (already applied or does not apply)"
        fi
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
