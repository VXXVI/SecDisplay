#!/usr/bin/env python3
"""Duet SFX 安装包结构分析：资源索引 + 数据区指纹定位。"""
import struct, sys, collections

def secmap(d, off):
    pe = struct.unpack_from('<I', d, off + 0x3c)[0]
    coff = off + pe + 4
    nsec = struct.unpack_from('<H', d, coff + 2)[0]
    optsz = struct.unpack_from('<H', d, coff + 16)[0]
    sec = coff + 20 + optsz
    out = []
    for i in range(nsec):
        o = sec + 40 * i
        nm = d[o:o + 8].rstrip(b'\0').decode()
        vsz, va, rsz, ptr = struct.unpack_from('<IIII', d, o + 8)
        out.append((nm, va, vsz, ptr, rsz))
    return out

def rsrc_tree(d, base):
    """打印资源树。"""
    def ents(off):
        nn, ni = struct.unpack_from('<HH', d, off + 12)
        return [(struct.unpack_from('<II', d, off + 16 + 8 * i)) for i in range(nn + ni)]
    res = []
    for typ, ofs in ents(base):
        sub = base + (ofs & 0x7fffffff)
        for nid, o2 in ents(sub):
            sub2 = base + (o2 & 0x7fffffff)
            nn, ni = struct.unpack_from('<HH', d, sub2 + 12)
            if nn + ni == 0:
                rva, sz = struct.unpack_from('<II', d, sub2)
                res.append((typ, nid, None, rva & 0x7fffffff, sz))
            else:
                for lang, o3 in ents(sub2):
                    rva, sz = struct.unpack_from('<II', d, base + (o3 & 0x7fffffff))
                    res.append((typ, nid, lang, rva & 0x7fffffff, sz))
    return res

def main(path):
    d = open(path, 'rb').read()
    print(f'文件: {path}  {len(d):,} 字节')
    sm = secmap(d, 0)
    print('\n分区:')
    for nm, va, vsz, ptr, rsz in sm:
        print(f'  {nm:10s} rva={va:#08x} vsz={vsz:>10,} raw={ptr:#08x} rsz={rsz:>10,}')
    rsrc = [s for s in sm if s[0] == '.rsrc'][0]
    base = rsrc[3]
    print('\n资源项:')
    for typ, nid, lang, rva, sz in rsrc_tree(d, base):
        nm = ''
        if rva + sz <= len(d) and 0 < sz <= 4096:
            blob = d[rva:rva + sz]
            if typ == 16:
                off = struct.unpack_from('<I', blob, 26)[0] if len(blob) > 30 else 0
                p = (off & 0x7fffffff)
                if p + 2 < len(blob):
                    ln = struct.unpack_from('<H', blob, p)[0]
                    nm = blob[p + 2:p + 2 + ln * 2].decode('utf-16le', 'ignore')
        print(f'  type={typ:>3} id={nid:#06x} lang={lang} size={sz:>8,} {nm}')

    # 数据区：找目录式（每 0x800/0x1000/0x2000 对齐的 PE 头）
    print('\n数据区 PE 头扫描（按常见对齐）:')
    payload_start = max(s[3] + s[4] for s in sm)
    print(f'  主 PE 镜像结束于 {payload_start:#x}')
    for step in (0x400, 0x800, 0x1000, 0x2000, 0x3400, 0x4000):
        hits = []
        p = payload_start
        while p < len(d) - 0x100:
            if d[p:p + 4] == b'MZ\x90\x00\x03\x00\x00\x00':
                hits.append(p)
            p += step
        print(f'  step={step:#06x}: {len(hits)} 个  前几个={[hex(h) for h in hits[:6]]}')

    # 压缩流特征：统计字节熵，找 0x3f0000~0x391800 区段
    print('\n区段熵值:')
    def ent(b):
        if not b:
            return 0
        c = collections.Counter(b)
        import math
        return -sum(v / len(b) * math.log2(v / len(b)) for v in c.values())
    for a in range(0x3f0000, 0x391800, 0x60000):
        print(f'  {a:#x}: {ent(d[a:a + 0x60000]):.3f} bits/byte')

if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'DuetDisplay-4-0-521.exe')
