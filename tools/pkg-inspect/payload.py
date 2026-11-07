#!/usr/bin/env python3
"""SFX 自解压安装包内嵌载荷提取器。

该安装包的 CAB 数据块与标准 MSZip 不同：块头为
    'CK' | u32 magic | u16 size | u16 uncompressed
后面才是原始 deflate 流。本脚本按这个实际格式解压。
"""
import struct, sys, os, zlib


def inflate_payload(blob):
    out = bytearray()
    p = 0
    n = len(blob)
    blocks = 0
    while p + 8 <= n:
        if blob[p:p + 2] != b'CK':
            # 向后找下一个块头，容忍少量对齐填充
            nxt = blob.find(b'CK', p + 1)
            if nxt < 0:
                break
            p = nxt
            continue
        magic = struct.unpack_from('<I', blob, p + 2)[0]
        size, unc = struct.unpack_from('<HH', blob, p + 6)
        data = blob[p + 10:p + 10 + size]
        r = None
        for skip in (0, 1, 2, 3):
            z = zlib.decompressobj(-15)
            try:
                o = z.decompress(data[skip:])
            except zlib.error:
                continue
            if len(o) > 1024:
                r = o
                break
        if r:
            out += r
            blocks += 1
        p += 10 + size
        if size == 0:
            break
    return bytes(out), blocks


def main(path, outdir, container_off=None):
    d = open(path, 'rb').read()
    if container_off is None:
        container_off = d.find(b'MSCF')
    blob = d[container_off:]
    out, blocks = inflate_payload(blob)
    print(f'容器偏移 {container_off:#x}  块数 {blocks}  解压后 {len(out):,} 字节')
    os.makedirs(outdir, exist_ok=True)
    dst = os.path.join(outdir, 'payload.bin')
    open(dst, 'wb').write(out)
    print(f'写出 {dst}')
    # 指纹
    for magic, name in [(b'\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1', 'CFB'),
                        (b'MZ\x90\x00', 'PE'), (b'MSCF', 'CAB'), (b'PK\x03\x04', 'ZIP')]:
        i = out.find(magic)
        print(f'  首个 {name}: {i if i >= 0 else "无"}')


if __name__ == '__main__':
    off = int(sys.argv[3], 0) if len(sys.argv) > 3 else None
    main(sys.argv[1], sys.argv[2], off)
