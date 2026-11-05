#!/usr/bin/env python3
"""从 Duet 的 SFX 安装包中提取内嵌 payload（MSI / CAB）。"""
import struct, sys, os, re

SIGS = [
    (b'\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1', 'msi'),
    (b'MSCF', 'cab'),
    (b'PK\x03\x04', 'zip'),
]

def carve(path, outdir, min_size=64 * 1024):
    data = open(path, 'rb').read()
    os.makedirs(outdir, exist_ok=True)
    found = []
    for magic, kind in SIGS:
        start = 0
        while True:
            i = data.find(magic, start)
            if i < 0:
                break
            start = i + 1
            found.append((i, kind))
    found.sort()
    # 用魔数出现的位置粗略估计对象长度：到下一个魔数或文件末尾
    results = []
    for idx, (off, kind) in enumerate(found):
        end = found[idx + 1][0] if idx + 1 < len(found) else len(data)
        size = end - off
        if size < min_size:
            continue
        name = f'{kind}_{off:08x}.{kind}'
        with open(os.path.join(outdir, name), 'wb') as fh:
            fh.write(data[off:end])
        results.append((name, off, size))
    return results

if __name__ == '__main__':
    for r in carve(sys.argv[1], sys.argv[2]):
        print(f'{r[0]:30s} off=0x{r[1]:08x} size={r[2]:,}')
