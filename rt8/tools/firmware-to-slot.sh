#!/bin/bash
# Write only the low-level firmware (LK, TEE, SCP, modem...) from a stock package to one slot.
# Use it when the preloader was updated and the other slot still has firmware from an older
# release (an old LK crashes under a newer preloader). It does not touch boot, vendor_boot,
# dtbo, vbmeta, super, userdata or misc. Can be re-run: parts already written are skipped.
# usage: firmware-to-slot.sh <firmware dir> <a|b> <work dir>
FW=$1; S=$2; W=$3
case $S in a|b) ;; *) echo "slot must be a or b"; exit 1 ;; esac
MTK="sudo $HOME/mtkclient/.venv/bin/python $HOME/mtkclient/mtk.py"
mkdir -p "$W"; DONE="$W/firmware-$S-done.txt"; touch "$DONE"
failed=""
for pf in md1img spmfw pi_img dpm scp sspm mcupm gz tee lk; do
    p=${pf}_$S; f="$FW/$pf.img"
    [ -f "$f" ] || { echo "missing $f"; exit 1; }
    grep -qx "$p" "$DONE" && { echo "--- $p already written"; continue; }
    for try in 1 2 3 4 5; do
        echo "=== $p (try $try). If it says it is waiting, unplug the tablet and plug it back in."
        if $MTK w "$p" "$f" 2>&1 | tee "$W/last-mtk.log" | grep -q 'Wrote '; then
            echo "$p" >> "$DONE"; echo "+++ $p OK"; break
        fi
        sleep 2
    done
    grep -qx "$p" "$DONE" || failed="$failed $p"
done
[ -z "$failed" ] && echo "ALL DONE" || echo "NOT WRITTEN:$failed (run again to retry)"
