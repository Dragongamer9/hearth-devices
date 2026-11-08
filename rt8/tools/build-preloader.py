#!/usr/bin/env python3
# Build a boot LU image (UFS_BOOT header + BRLYT + preloader) from the tablet's current boot1/boot2
# dump and a new preloader .bin from a firmware package (GFH image starting with "MMM\x01").
# Only writes the output when every layout check passes.
# usage: build-preloader.py <boot1 dump> <package preloader.bin> <out>
import struct, sys

dump = open(sys.argv[1], 'rb').read()
pkg = open(sys.argv[2], 'rb').read()

def fail(msg):
    sys.exit('STOP: ' + msg + ' (nothing written)')

if dump[:8] != b'UFS_BOOT': fail('dump does not start with UFS_BOOT')
if pkg[:4] != b'MMM\x01': fail('package preloader does not start with MMM\\x01')
brlyt = struct.unpack_from('<I', dump, 0x10)[0]
if dump[brlyt:brlyt + 5] != b'BRLYT': fail('no BRLYT at 0x%x' % brlyt)
start, end = struct.unpack_from('<II', dump, brlyt + 0xC)
if dump[start:start + 4] != b'MMM\x01': fail('no preloader at 0x%x' % start)
oldlen = struct.unpack_from('<I', dump, start + 0x20)[0]
newlen = struct.unpack_from('<I', pkg, 0x20)[0]
print('BRLYT at 0x%x, image start 0x%x, end field 0x%x' % (brlyt, start, end))
print('old image length 0x%x (start+len = 0x%x), new image length 0x%x, package file 0x%x' % (
    oldlen, start + oldlen, newlen, len(pkg)))
print('BRLYT bytes:', dump[brlyt:brlyt + 0x24].hex())
if newlen > len(pkg) or newlen < 0x10000: fail('package length field looks wrong')
if start + newlen > len(dump): fail('new image does not fit')
if end not in (start + oldlen, start + oldlen - 1): fail('BRLYT end field is not start+length; layout unknown')
newend = start + newlen - (start + oldlen - end)
out = bytearray(dump[:start]) + pkg[:newlen]
out += b'\0' * (len(dump) - len(out))
struct.pack_into('<I', out, brlyt + 0x10, newend)
open(sys.argv[3], 'wb').write(out)
print('OK: wrote %s (%d bytes), end field 0x%x -> 0x%x' % (sys.argv[3], len(out), end, newend))
