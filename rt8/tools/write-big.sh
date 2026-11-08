#!/bin/bash
# Write a large raw image to the tablet in 1 GiB pieces with mtkclient's "wo".
# (mtkclient's "w" reads the whole file into memory, which kills it for the 6 GB super image.)
# usage: write-big.sh <raw image> <partition byte offset from printgpt, e.g. 0x57800000> <work dir>
IMG=$1; BASE=$(( $2 )); W=$3
MTK="sudo $HOME/mtkclient/.venv/bin/python $HOME/mtkclient/mtk.py"
PIECE=$(( 1 << 30 ))
SIZE=$(stat -c %s "$IMG")
N=$(( (SIZE + PIECE - 1) / PIECE ))
mkdir -p "$W/pieces"; touch "$W/pieces-done.txt"
failed=""
for i in $(seq 0 $((N - 1))); do
    grep -qx "$i" "$W/pieces-done.txt" && { echo "--- piece $((i+1))/$N already written"; continue; }
    P="$W/pieces/piece$i.bin"
    [ -f "$P" ] || dd if="$IMG" of="$P" bs=1M skip=$((i * 1024)) count=1024 status=none
    LEN=$(stat -c %s "$P")
    OFF=$(printf '0x%x' $(( BASE + i * PIECE )))
    for try in 1 2 3 4 5; do
        echo "=== piece $((i+1))/$N at $OFF (try $try). If it says it is waiting, unplug the tablet and plug it back in."
        if $MTK wo "$OFF" "$LEN" "$P" 2>&1 | tee "$W/last-mtk.log" | grep -q 'Wrote '; then
            echo "$i" >> "$W/pieces-done.txt"; rm -f "$P"; echo "+++ piece $((i+1))/$N OK"; break
        fi
        sleep 2
    done
    grep -qx "$i" "$W/pieces-done.txt" || failed="$failed $((i+1))"
done
[ -z "$failed" ] && echo "ALL DONE" || echo "NOT WRITTEN: pieces$failed (run again to retry)"
