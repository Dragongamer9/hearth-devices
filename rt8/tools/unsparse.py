#!/usr/bin/env python3
# Expand an Android sparse image (magic ed26ff3a) into a raw image that mtkclient can write.
# Skipped regions become holes in the output file, so it takes little real disk space.
# usage: unsparse.py in.img out.img
import struct, sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, 'rb') as f, open(dst, 'wb') as o:
    magic, major, minor, fhdr, chdr, blk, total_blks, total_chunks, _ = struct.unpack('<IHHHHIIII', f.read(28))
    if magic != 0xED26FF3A:
        sys.exit('not a sparse image')
    f.seek(fhdr)
    for n in range(total_chunks):
        ctype, _, cblks, csize = struct.unpack('<HHII', f.read(12))
        f.seek(chdr - 12, 1)
        size = cblks * blk
        if ctype == 0xCAC1:                       # raw data
            left = size
            while left:
                buf = f.read(min(left, 16 << 20))
                o.write(buf)
                left -= len(buf)
        elif ctype == 0xCAC2:                     # fill with a 4-byte pattern
            pat = f.read(4)
            if pat == b'\0\0\0\0':
                o.seek(size, 1)
            else:
                chunk = pat * ((1 << 20) // 4)
                left = size
                while left:
                    w = min(left, len(chunk))
                    o.write(chunk[:w])
                    left -= w
        elif ctype == 0xCAC3:                     # don't care
            o.seek(size, 1)
        elif ctype == 0xCAC4:                     # crc32, ignored
            f.read(4)
        else:
            sys.exit('unknown chunk type %x' % ctype)
        if n % 500 == 0:
            print('\r%d/%d chunks' % (n, total_chunks), end='', flush=True)
    o.truncate(total_blks * blk)
print('\rdone: %s, %d bytes' % (dst, total_blks * blk))
