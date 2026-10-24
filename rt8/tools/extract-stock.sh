#!/usr/bin/env bash
# Extract the pieces of the stock Oukitel RT8 firmware the Hearth port needs.
#
#   tools/extract-stock.sh <path/to/OUKITEL_RT8_*.zip | unpacked firmware dir>
#
# Writes into devices/rt8/stock/ (git-ignored — Oukitel's binaries are never
# committed):
#   vendor.dtb   device tree from vendor_boot.img (prebuilt DTB for first boot)
#   dtbo.img     stock DT overlays
#   modules/     stock vendor_boot kernel modules (reference only)
#   panels.txt   display timings recovered from the stock panel modules
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:?usage: $0 <firmware.zip|firmware dir>}"
OUT="$HERE/stock"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

if [[ -f "$SRC" ]]; then
    echo ">> unpacking $(basename "$SRC")"
    python3 -I - "$SRC" "$WORK/fw" <<'EOF'
import sys, zipfile, pathlib
def ex(z, dest):
    with zipfile.ZipFile(z) as f: f.extractall(dest)
    for inner in pathlib.Path(dest).rglob('*.zip'):
        ex(inner, inner.with_suffix(''))
ex(sys.argv[1], sys.argv[2])
EOF
    SRC="$WORK/fw"
fi

find_img() { find "$SRC" -name "$1" -print -quit; }
BOOT="$(find_img boot.img)"; VBOOT="$(find_img vendor_boot.img)"; DTBO="$(find_img dtbo.img)"
for f in "$BOOT" "$VBOOT" "$DTBO"; do [[ -n "$f" ]] || { echo "missing image in firmware" >&2; exit 1; }; done

python3 -I "$HERE/tools/bootimg.py" unpack "$BOOT" "$VBOOT" "$WORK/img" > "$OUT/stock-info.json"

# MediaTek prefixes the vendor_boot DTB with a 64-byte header; keep the raw FDT.
python3 -I - "$WORK/img/vendor.dtb" "$OUT/vendor.dtb" <<'EOF'
import sys
d = open(sys.argv[1], 'rb').read()
i = d.find(b'\xd0\x0d\xfe\xed')
assert i >= 0, 'no FDT in vendor_boot dtb'
size = int.from_bytes(d[i+4:i+8], 'big')
open(sys.argv[2], 'wb').write(d[i:i+size])
EOF
cp "$DTBO" "$OUT/dtbo.img"

echo ">> extracting stock vendor modules"
mkdir -p "$WORK/vr" "$OUT/modules"
( cd "$WORK/vr" && { lz4 -dc "$WORK/img/vendor_ramdisk" 2>/dev/null || cat "$WORK/img/vendor_ramdisk"; } | cpio -idm --quiet )
find "$WORK/vr" -name '*.ko' -exec cp {} "$OUT/modules/" \;
cp "$WORK/vr"/lib/modules/modules.load "$OUT/modules/" 2>/dev/null || true

echo ">> recovering panel timings"
python3 -I - "$OUT"/modules/panel-*.ko > "$OUT/panels.txt" <<'EOF'
import sys, struct
for p in sys.argv[1:]:
    d = open(p, 'rb').read(); seen = set()
    print(p.rsplit('/', 1)[-1])
    for i in range(4, len(d) - 18, 2):
        hd, hs, he, ht, hk, vd, vs, ve, vt = struct.unpack_from('<9H', d, i)
        if hd == 1200 and vd == 1920 and hd < hs < he < ht < 1600 and vd < vs < ve < vt < 4000:
            clk = struct.unpack_from('<i', d, i - 4)[0]
            key = (clk, hs, he, ht, vs, ve, vt)
            if key in seen or clk <= 0: continue
            seen.add(key)
            print(f'  clock={clk} kHz  h=1200/{hs}/{he}/{ht}  v=1920/{vs}/{ve}/{vt}  '
                  f'{clk * 1000 / (ht * vt):.1f} Hz')
EOF

echo ">> done: $(ls "$OUT")"
grep -o '"header_version": [0-9]*' "$OUT/stock-info.json" | sort -u
