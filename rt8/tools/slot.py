#!/usr/bin/env python3
# Show or switch the active A/B slot in a dump of the misc partition.
import sys, struct, zlib
# usage: slot.py misc.bin            -> show
#        slot.py misc.bin a out.bin  -> make slot a active, write copy to out.bin
OFF = 2048
d = bytearray(open(sys.argv[1], 'rb').read())
b = d[OFF:OFF+32]
magic = struct.unpack_from('<I', b, 4)[0]
crc = struct.unpack_from('<I', b, 28)[0]
ok = magic == 0x42414342 and crc == (zlib.crc32(bytes(b[:28])) & 0xffffffff)
def show(b):
    print('suffix', bytes(b[:4]).rstrip(b'\0'), 'magic %08x' % struct.unpack_from('<I', b, 4)[0], 'nb_slot', b[9] & 7)
    for i, n in enumerate('ab'):
        s0, s1 = b[12+2*i], b[13+2*i]
        print(' slot', n, 'priority', s0 & 15, 'tries', (s0 >> 4) & 7, 'successful', s0 >> 7, 'verity_bad', s1 & 1)
show(b)
print('valid' if ok else 'NOT a valid boot-control block - stop, do not write anything')
if len(sys.argv) > 2 and ok:
    want = 0 if sys.argv[2] == 'a' else 1
    for i in range(2):
        s0 = b[12+2*i]
        if i == want: s0 = 15 | (7 << 4) | (s0 & 0x80)
        else: s0 = 14 | (s0 & 0xF0)
        b[12+2*i] = s0
    b[0:4] = (b'_a' if want == 0 else b'_b') + b'\0\0'
    struct.pack_into('<I', b, 28, zlib.crc32(bytes(b[:28])) & 0xffffffff)
    d[OFF:OFF+32] = b
    open(sys.argv[3], 'wb').write(d)
    print('--- new:'); show(b); print('written', sys.argv[3])
