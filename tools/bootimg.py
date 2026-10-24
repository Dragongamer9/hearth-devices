#!/usr/bin/env python3
"""Minimal Android boot image tool for the Hearth RT8 port.

Handles exactly what the Oukitel RT8 uses: boot.img header v4 (GKI) and
vendor_boot.img header v4. No external mkbootimg needed.

  bootimg.py info   <img>
  bootimg.py unpack <boot.img> <vendor_boot.img> <outdir>
  bootimg.py pack-boot   --kernel Image.gz --ramdisk rd.cpio.gz -o boot.img
                         [--os-version 12.0.0] [--os-patch 2099-12] [--cmdline ""]
                         [--partition-size 67108864]
  bootimg.py pack-vendor --ramdisk vendor_rd --dtb vendor.dtb -o vendor_boot.img
                         [--cmdline "bootopt=64S3,32N2,64N2"] [--partition-size 67108864]

Defaults match the stock RT8 V14 (2026-08-28) firmware.
"""
import argparse, gzip, json, os, struct, sys

PAGE = 4096
KERNEL_ADDR, RAMDISK_ADDR, TAGS_ADDR, DTB_ADDR = 0x40000000, 0x66f00000, 0x47c80000, 0x47c80000

def align(n, p=PAGE): return (n + p - 1) // p * p
def pad(b, p=PAGE): return b + b'\0' * (align(len(b), p) - len(b))

def enc_os(version, patch):
    a, b, c = (int(x) for x in version.split('.'))
    y, m = (int(x) for x in patch.split('-'))
    return (((a << 14) | (b << 7) | c) << 11) | (((y - 2000) << 4) | m)

def dec_os(v):
    ver, p = v >> 11, v & 0x7ff
    return f'{ver >> 14}.{(ver >> 7) & 0x7f}.{ver & 0x7f}', f'{(p >> 4) + 2000}-{p & 0xf:02d}'

# ---------------------------------------------------------------- boot v4
def read_boot(d):
    assert d[:8] == b'ANDROID!', 'not a boot image'
    ksz, rsz, osv, hsz = struct.unpack_from('<4I', d, 8)
    hv, = struct.unpack_from('<I', d, 40)
    assert hv in (3, 4), f'boot header v{hv} not supported'
    cmd = d[44:44 + 1536].split(b'\0')[0].decode()
    k = d[PAGE:PAGE + ksz]
    ro = PAGE + align(ksz)
    ver, patch = dec_os(osv)
    return dict(header_version=hv, kernel=k, ramdisk=d[ro:ro + rsz],
                os_version=ver, os_patch=patch, cmdline=cmd)

def pack_boot(kernel, ramdisk, os_version, os_patch, cmdline):
    hdr = b'ANDROID!' + struct.pack('<4I', len(kernel), len(ramdisk),
                                    enc_os(os_version, os_patch), 1584)
    hdr += b'\0' * 16 + struct.pack('<I', 4)
    hdr += cmdline.encode().ljust(1536, b'\0')
    hdr += struct.pack('<I', 0)  # boot signature size (unsigned; vbmeta disabled)
    assert len(hdr) == 1584
    return pad(hdr) + pad(kernel) + pad(ramdisk)

# ---------------------------------------------------------- vendor_boot v4
def read_vendor(d):
    assert d[:8] == b'VNDRBOOT', 'not a vendor_boot image'
    hv, page, kaddr, raddr, vrsz = struct.unpack_from('<5I', d, 8)
    cmd = d[28:28 + 2048].split(b'\0')[0].decode()
    o = 28 + 2048 + 4 + 16
    hsz, dtbsz = struct.unpack_from('<2I', d, o)
    tbl_sz, ent_n, ent_sz, bc_sz = struct.unpack_from('<4I', d, o + 16)
    ro = align(hsz, page)
    do = ro + align(vrsz, page)
    return dict(header_version=hv, page_size=page, cmdline=cmd,
                ramdisk=d[ro:ro + vrsz], dtb=d[do:do + dtbsz],
                ramdisk_entries=ent_n, bootconfig_size=bc_sz)

def pack_vendor(ramdisk, dtb, cmdline):
    # One "platform" ramdisk fragment, like stock.
    entry = struct.pack('<3I', len(ramdisk), 0, 1) + b'\0' * 32 + b'\0' * 64
    hdr = b'VNDRBOOT' + struct.pack('<5I', 4, PAGE, KERNEL_ADDR, RAMDISK_ADDR, len(ramdisk))
    hdr += cmdline.encode().ljust(2048, b'\0')
    hdr += struct.pack('<I', TAGS_ADDR) + b'\0' * 16
    hdr += struct.pack('<2I', 2128, len(dtb)) + struct.pack('<Q', DTB_ADDR)
    hdr += struct.pack('<4I', len(entry), 1, len(entry), 0)
    assert len(hdr) == 2128, len(hdr)
    return pad(hdr) + pad(ramdisk) + pad(dtb) + pad(entry)

# ------------------------------------------------------------ dtbo (DT table)
def pack_dtbo(blobs):
    """Android DT table, matching the stock RT8 layout (page 2048, v0)."""
    n = len(blobs)
    off = 32 + 32 * n
    entries, body = b'', b''
    for i, b in enumerate(blobs):
        entries += struct.pack('>8I', len(b), off + len(body), i, 0, 0, 0, 0, 0)
        body += b
    total = off + len(body)
    return struct.pack('>8I', 0xd7b7ab1e, total, 32, 32, n, 32, 2048, 0) + entries + body

# --------------------------------------------------------------------- cli
def write_img(path, data, part_size):
    if part_size and len(data) > part_size:
        sys.exit(f'{path}: {len(data)} bytes exceeds partition size {part_size}')
    open(path, 'wb').write(data)
    print(f'wrote {path} ({len(data)} bytes)')

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('info'); s.add_argument('img')
    s = sub.add_parser('unpack'); s.add_argument('boot'); s.add_argument('vendor'); s.add_argument('out')
    s = sub.add_parser('pack-boot')
    s.add_argument('--kernel', required=True); s.add_argument('--ramdisk', required=True)
    s.add_argument('--os-version', default='12.0.0'); s.add_argument('--os-patch', default='2099-12')
    s.add_argument('--cmdline', default=''); s.add_argument('--partition-size', type=int, default=67108864)
    s.add_argument('-o', required=True)
    s = sub.add_parser('pack-vendor')
    s.add_argument('--ramdisk', required=True); s.add_argument('--dtb', required=True)
    s.add_argument('--cmdline', default='bootopt=64S3,32N2,64N2')
    s.add_argument('--partition-size', type=int, default=67108864)
    s.add_argument('-o', required=True)
    s = sub.add_parser('pack-dtbo'); s.add_argument('dtbs', nargs='+'); s.add_argument('-o', required=True)
    a = ap.parse_args()

    if a.cmd == 'info':
        d = open(a.img, 'rb').read()
        r = read_boot(d) if d[:8] == b'ANDROID!' else read_vendor(d)
        print(json.dumps({k: (len(v) if isinstance(v, bytes) else v) for k, v in r.items()}, indent=1))
    elif a.cmd == 'unpack':
        os.makedirs(a.out, exist_ok=True)
        b = read_boot(open(a.boot, 'rb').read())
        v = read_vendor(open(a.vendor, 'rb').read())
        open(f'{a.out}/kernel', 'wb').write(b['kernel'])
        if b['kernel'][:2] == b'\x1f\x8b':
            open(f'{a.out}/Image', 'wb').write(gzip.decompress(b['kernel']))
        open(f'{a.out}/boot_ramdisk', 'wb').write(b['ramdisk'])
        open(f'{a.out}/vendor_ramdisk', 'wb').write(v['ramdisk'])
        open(f'{a.out}/vendor.dtb', 'wb').write(v['dtb'])
        print(json.dumps(dict(boot={k: x for k, x in b.items() if not isinstance(x, bytes)},
                              vendor_boot={k: x for k, x in v.items() if not isinstance(x, bytes)}), indent=1))
    elif a.cmd == 'pack-boot':
        write_img(a.o, pack_boot(open(a.kernel, 'rb').read(), open(a.ramdisk, 'rb').read(),
                                 a.os_version, a.os_patch, a.cmdline), a.partition_size)
    elif a.cmd == 'pack-dtbo':
        write_img(a.o, pack_dtbo([open(p, 'rb').read() for p in a.dtbs]), 8388608)
    elif a.cmd == 'pack-vendor':
        write_img(a.o, pack_vendor(open(a.ramdisk, 'rb').read(), open(a.dtb, 'rb').read(),
                                   a.cmdline), a.partition_size)

if __name__ == '__main__':
    main()
