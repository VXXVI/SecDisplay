#!/usr/bin/env python3
"""从文件头部提取内嵌 CAB 并自愈式解压（MSZip 原始 deflate）。

用法: python3 cab.py <内嵌cab文件> <输出目录> [最大文件数]
"""
import struct, sys, os, zlib

FIXED = struct.Struct('<4sIIIIIBBHHHHH')


def inflate_mszip(raw, cbUncomp):
    """逐块 MSZip 解压。返回 (data, consumed)。"""
    out = b''
    b = raw
    while len(out) < cbUncomp and len(b) >= 5:
        if b[:2] not in (b'CK', b'PC'):
            break
        sz = struct.unpack_from('<H', b, 2)[0]
        blk = b[4:4 + sz]
        got = b''
        for start in range(0, 3):
            try:
                d = zlib.decompressobj(-15)
                got = d.decompress(blk[start:])
                if got:
                    break
            except zlib.error:
                got = b''
        if not got:
            break
        out += got
        b = b[4 + sz:]
    return out


def parse(data, verbose=True):
    hdr = FIXED.unpack_from(data, 0)
    sig, r1, cbCab, r2, coffFiles, r3, vmin, vmaj, cF, cFiles, flags, setID, idx = hdr
    assert sig == b'MSCF'
    # 可选/保留头部：本样本是 12 字节（含 cbCFHeader/cbCFFolder/cbCFData 与保留段）
    p = FIXED.size + 12
    folders = []
    for i in range(cF):
        f = struct.unpack_from('<IHH', data, p)
        p += 8
        folders.append({'off': f[0], 'n': f[1], 'cfg': f[2] & 0xF, 'buf': None})
    files = []
    off = coffFiles
    for i in range(cFiles):
        cb, uoff, ifold, dt, tm, attr = struct.unpack_from('<IIHHHH', data, off)
        e = data.index(b'\x00', off + 16)
        name = data[off + 16:e].decode('cp1252', 'replace')
        off = e + 1
        files.append((name, cb, uoff, ifold))
    if verbose:
        print(f'folders={cF} files={cFiles} flags=0x{flags:04x}', file=sys.stderr)
        for n, cb, uo, f in files:
            print(f'  {n:70s} {cb:>12,}', file=sys.stderr)

    for fo in folders:
        if fo['cfg'] != 1:
            raise NotImplementedError(f"cfg={fo['cfg']}")
        q = fo['off']
        buf = b''
        for _ in range(fo['n']):
            csum, cbData, cbUncomp = struct.unpack_from('<IHH', data, q)
            q += 8
            buf += inflate_mszip(data[q:q + cbData], cbUncomp)
            q += cbData
        fo['buf'] = buf
    return files, folders


def main(src, outdir, limit=10 ** 9):
    os.makedirs(outdir, exist_ok=True)
    data = open(src, 'rb').read()
    files, folders = parse(data)
    n = 0
    for name, cb, uoff, ifold in files:
        if n >= limit:
            break
        buf = folders[ifold]['buf']
        blob = buf[uoff:uoff + cb]
        out = os.path.join(outdir, name.lstrip('\\').replace('\\', '/'))
        os.makedirs(os.path.dirname(out), exist_ok=True)
        open(out, 'wb').write(blob)
        n += 1
        print(f'{name:70s} {cb:>12,}')
    print(f'\n写出 {n} 个文件 -> {outdir}', file=sys.stderr)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 10 ** 9)
