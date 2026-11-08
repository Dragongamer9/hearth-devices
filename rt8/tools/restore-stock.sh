#!/bin/bash
# Put the stock Oukitel firmware back on slot A with mtkclient, one partition per call.
# Skips the preloader. Can be re-run: partitions already written are skipped.
# usage: restore-stock.sh <firmware dir> <work dir>
FW=$1; W=$2
MTK="sudo $HOME/mtkclient/.venv/bin/python $HOME/mtkclient/mtk.py"
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$W"
[ -f "$W/super.raw" ] || python3 "$HERE/unsparse.py" "$FW/super.img" "$W/super.raw" || exit 1
[ -f "$W/zero16.bin" ] || head -c 16M /dev/zero > "$W/zero16.bin"
[ -f "$W/zero64.bin" ] || head -c 64M /dev/zero > "$W/zero64.bin"
touch "$W/restore-done.txt"
failed=""
for pf in boot_a:boot.img vendor_boot_a:vendor_boot.img dtbo_a:dtbo.img \
          vbmeta_a:vbmeta.img vbmeta_system_a:vbmeta_system.img vbmeta_vendor_a:vbmeta_vendor.img \
          md1img_a:md1img.img spmfw_a:spmfw.img pi_img_a:pi_img.img dpm_a:dpm.img scp_a:scp.img \
          sspm_a:sspm.img mcupm_a:mcupm.img gz_a:gz.img tee_a:tee.img lk_a:lk.img logo:logo.bin \
          super:@super.raw userdata:@zero64.bin metadata:@zero16.bin; do
    p=${pf%%:*}; f=${pf#*:}
    case $f in @*) f="$W/${f#@}" ;; *) f="$FW/$f" ;; esac
    grep -qx "$p" "$W/restore-done.txt" && { echo "--- $p already written"; continue; }
    for try in 1 2 3 4 5; do
        echo "=== $p (try $try). If it says it is waiting, unplug the tablet and plug it back in."
        if $MTK w "$p" "$f" 2>&1 | tee "$W/last-mtk.log" | grep -q 'Wrote '; then
            echo "$p" >> "$W/restore-done.txt"; echo "+++ $p OK"; break
        fi
        sleep 2
    done
    grep -qx "$p" "$W/restore-done.txt" || failed="$failed $p"
done
[ -z "$failed" ] && echo "ALL DONE" || echo "NOT WRITTEN:$failed (run again to retry)"
