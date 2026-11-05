#!/usr/bin/env python3
"""Duet SFX 内嵌 CAB 提取器（自愈版）。

思路：SFX 在文件尾追加了 cab 数据流，CAB 头里的偏移字段相对容器起点或绝对偏移，
两种都试；MSZip 块用原始 deflate 解码，遇到错位就在附近搜索正确的块起点。
"""
import struct, sys, zlib, os

CK = b'CK'


def try_inflate(blob, want):
    """尝试解出一块 MSZip 数据，返回 (data, consumed, start_hint)。"""
    best = None
    for skip in range(0, 16):
        if len(blob) - skip < 3:
            break
        z = zlib.decompressobj(-15)
        try:
            out = z.decompress(blob[skip:], want)
        except zlib.error:
            continue
        if len(out) > 1024:
            if best is None or len(out) > len(best[0]):
                best = (out, skip)
    return best


def extract(path, outdir):
    d = open(path, 'rb').read()
    n = len(d)
    print(f'容器 {n:,} 字节')
    # 定位有效 CAB 头（cbCabinet 与实际相符或接近）
    heads = []
    i = 0
    while True:
        i = d.find(b'MSCF', i)
        if i < 0:
            break
        try:
            _, _, cb, _, coffFiles, _, vmaj, vmin, cF, cFiles, flags, sid, idx = \
                struct.unpack_from('<4sIIIIIBBHHHHH', d, i)
            if 1 <= cF <= 8 and 1 <= cFiles <= 100000:
                heads.append((i, cb, cF, cFiles, flags))
        except struct.error:
            pass
        i += 1
    for h in heads:
        print('  header', hex(h[0]), 'cb', h[1], 'folders', h[2], 'files', h[3], 'flags', hex(h[4]))
    if not heads:
        return
    start, cb, cF, cFiles, flags = max(heads, key=lambda h: h[1])
    # 数据区：从 start 到文件末尾
    blob = d[start:start + (cb if cb > 4096 else n - start)]
    # 找到所有 CK 块，串起来试解码
    pos = blob.find(CK)
    print(f'  首个 CK 位于容器偏移 {start + pos:#x}')
    out = b''
    cur = pos
    fails = 0
    while cur >= 0 and len(out) < 200 * 1024 * 1024:
        nxt = blob.find(CK, cur + 3)
        end = nxt if nxt > 0 else len(blob)
        r = try_inflate(blob[cur + 4:end], 32768)
        if r:
            out += r[0]
            fails = 0
        else:
            fails += 1
            if fails > 50:
                break
        cur = nxt
    print(f'  累计解压 {len(out):,} 字节')
    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, 'payload.bin'), 'wb').write(out)


if __name__ == '__main__':
    extract(sys.argv[1], sys.argv[2])
