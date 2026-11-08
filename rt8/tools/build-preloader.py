#!/usr/bin/env python3
# Build a boot LU image (UFS_BOOT header + BRLYT + preloader) from the tablet's current boot1/boot2
# dump and a new preloader .bin from a firmware package (GFH image starting with "MMM\x01").
# The header and BRLYT are kept; the preloader image is swapped, and the single BRLYT field that
# holds the image end (or length) is updated. Only writes the output when every check passes.
# usage: build-preloader.py <boot1 dump> <package preloader.bin> <out>
import struct, sys

dump = open(sys.argv[1], 'rb').read()
pkg = open(sys.argv[2], 'rb').read()

def fail(msg):
    sys.exit('STOP: ' + msg + ' (nothing written)')

if dump[:8] != b'UFS_BOOT': fail('dump does not start with UFS_BOOT')
if pkg[:4] != b'MMM\x01': fail('package preloader does not start with MMM\\x01')
start = dump.find(b'MMM\x01')
brlyt = dump.find(b'BRLYT', 0, start)
if start <= 0 or brlyt <= 0: fail('could not find BRLYT and the preloader image')
oldlen = struct.unpack_from('<I', dump, start + 0x20)[0]
newlen = struct.unpack_from('<I', pkg, 0x20)[0]
print('BRLYT at 0x%x, image at 0x%x, old length 0x%x, new length 0x%x, package file 0x%x' % (
    brlyt, start, oldlen, newlen, len(pkg)))
region = dump[brlyt:brlyt + 0x40]
print('BRLYT:', region.hex(' '))
fields = [(o, struct.unpack_from('<I', region, o)[0]) for o in range(0, 0x40, 4)]
starts = [o for o, v in fields if v == start]
ends = [o for o, v in fields if v in (start + oldlen, start + oldlen - 1)]
lens = [o for o, v in fields if v == oldlen]
# Some layouts give the preloader a fixed area: the end fields mark the area, not the image.
areas = sorted({v for o, v in fields if start + oldlen < v <= len(dump)})
print('start field at', [hex(o) for o in starts], '| end field at', [hex(o) for o in ends],
      '| length field at', [hex(o) for o in lens], '| fixed area ends', [hex(v) for v in areas])
if newlen > len(pkg) or newlen < 0x10000: fail('package length field looks wrong')
if not starts: fail('BRLYT has no field pointing at the image')
out = bytearray(dump)
if not ends and not lens and len(areas) == 1:
    area_end = areas[0]
    if start + newlen > area_end: fail('new image is larger than the fixed area')
    out[start:area_end] = pkg[:newlen] + b'\0' * (area_end - start - newlen)
    open(sys.argv[3], 'wb').write(out)
    print('OK: wrote %s (%d bytes); fixed area 0x%x-0x%x, BRLYT unchanged' % (sys.argv[3], len(out), start, area_end))
    sys.exit(0)
if len(ends) + len(lens) != 1: fail('BRLYT layout not recognised')
if start + newlen > len(dump): fail('new image does not fit')
out = bytearray(dump[:start]) + pkg[:newlen]
out += b'\0' * (len(dump) - len(out))
if ends:
    o = brlyt + ends[0]; old = struct.unpack_from('<I', out, o)[0]
    new = old - (start + oldlen) + start + newlen
else:
    o = brlyt + lens[0]; old = oldlen; new = newlen
struct.pack_into('<I', out, o, new)
open(sys.argv[3], 'wb').write(out)
print('OK: wrote %s (%d bytes), BRLYT field at 0x%x: 0x%x -> 0x%x' % (sys.argv[3], len(out), o, old, new))
