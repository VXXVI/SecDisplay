#!/usr/bin/env python3
"""最小化 CAB 解析器（MS-CAB），支持跨 cabinet 链。

只做提取，不解压算法之外的复杂语义。压缩算法交给 macOS 自带 libarchive（bsdtar）/系统 `tar` 不支持 cab，
因此这里先实现 MSZip 和 None，遇到 LZX/Quantum 就如实报出。
"""
import struct, sys, os, zlib

FIXED = struct.Struct('<4sIIIIIBBHHHHH')
CFHEADER = struct.Struct('<4sIIIIIBBHHHHH')
CFFOLDER = struct.Struct('<IHH')
CFFILE = struct.Struct('<IIHHHH')
CFDATA = struct.Struct('<IHH')


def parse_chain(path):
    """跨 cabinet 链读取所有文件条目。返回 {name: (folder_idx, offset, size)} 与 folder 列表。"""
    blocks = []
    seen = set()
    cur = path
    while cur and cur not in seen:
        seen.add(cur)
        d = open(cur, 'rb').read()
        (sig, reserved1, cbCabinet, reserved2, coffFiles, reserved3,
         versionMinor, versionMajor, cFolders, cFiles, flags,
         setID, iCabinet) = CFHEADER.unpack_from(d, 0)
        assert sig == b'MSCF', sig
        # 找可选头
        p = CFHEADER.size
        cbCFHeader = 0
        cbCFFolder = 0
        cbCFData = 0
        if flags & 0x0004:  # prev cabinet
            j = d.index(b'\x00', p); p = j + 1
        if flags & 0x0001:
            j = d.index(b'\x00', p); p = j + 1
        if flags & 0x0002:
            j = d.index(b'\x00', p); p = j + 1
        if flags & 0x0004:
            j = d.index(b'\x00', p); p = j + 1
        if flags & 0x0004:
            pass
        # 收集链接字符串（顺序：prev, next）—— 上面已消耗，简化处理
        folders = []
        for i in range(cFolders):
            coffCabStart, cCFData, typeCompress = CFFOLDER.unpack_from(d, p)
            p += CFFOLDER.size
            folders.append({'data_off': coffCabStart, 'n_data': cCFData,
                            'type': typeCompress, 'buf': bytearray(), 'cab': d})
        blocks.append((d, coffFiles, cFiles, folders, cbCFHeader))
        # next cabinet
        nxt = None
        if flags & 0x0004:
            # re-scan strings properly
            q = CFHEADER.size
            names = []
            for _ in range(2):
                if q < len(d) and d[q:q+1] != b'\x00' and d[q] == 0 and q == 0:
                    pass
            # 简单法：首个字符串区在 header 之后
            q = CFHEADER.size
            s1 = d[q:d.index(b'\x00', q)].decode('ascii', 'ignore')
            q = d.index(b'\x00', q) + 1
            s2 = d[q:d.index(b'\x00', q)].decode('ascii', 'ignore')
            nxt = s1 or s2
        body = d[coffFiles:]
        # 简化：直接返回第一个 cabinet 的局部解析结果 + 记录 next 名
        cur = None if not nxt else os.path.join(os.path.dirname(path), nxt)
    return blocks


def main(path, outdir):
    os.makedirs(outdir, exist_ok=True)
    d = open(path, 'rb').read()
    (sig, r1, cbCabinet, r2, coffFiles, r3, vminor, vmajor,
     cFolders, cFiles, flags, setID, iCabinet) = CFHEADER.unpack_from(d, 0)
    print(f'cabinet: flags=0x{flags:04x} folders={cFolders} files={cFiles} '
          f'version={vmajor}.{vminor} setID={setID} idx={iCabinet} cbCabinet={cbCabinet:,}')

    p = CFHEADER.size
    # 可选头：保留区 / 头保留 / 数据保留 先于链接字符串
    cbCFHeader = 0
    if flags & 0x0004:  # 有 cbCFHeader 字段
        cbCFHeader, cbCFFolder, cbCFData = struct.unpack_from('<HBB', d, p)
        p += 4
        p += cbCFHeader
    links = {}
    for bit, name in ((0x0004, 'prev'), (0x0001, 'next')):
        if flags & bit:
            e = d.index(b'\x00', p)
            links[name] = d[p:e].decode('ascii', 'ignore')
            p = e + 1
    if links:
        print('links:', links)

    folders = []
    for i in range(cFolders):
        coffCabStart, cCFData, typeCompress = CFFOLDER.unpack_from(d, p)
        p += CFFOLDER.size
        folders.append({'off': coffCabStart, 'n': cCFData,
                        'cfg': typeCompress & 0x000F, 'win': typeCompress >> 8,
                        'buf': bytearray()})

    # 解压各 folder
    HDR = CFHEADER.size + (4 if flags & 0x0004 else 0) + cbCFHeader
    linklen = sum(len(v.encode('ascii')) + 1 for v in links.values())
    for idx, fo in enumerate(folders):
        cfg = fo['cfg']
        q = HDR + linklen + cFolders * CFFOLDER.size + idx * 0  # placeholder
        # 数据块从 coffCabStart 开始（用 folder offset 字段值）
        q = fo['off']
        buf = bytearray()
        prev = b''
        for _ in range(fo['n']):
            csum, cbData, cbUncomp = CFDATA.unpack_from(d, q)
            q += CFDATA.size
            raw = d[q:q + cbData]
            q += cbData
            if cfg == 0:  # none
                buf += raw
            elif cfg == 1:  # MSZIP
                data = b''
                b = raw
                while b:
                    if b[:2] not in (b'CK', b'PC'):
                        raise ValueError(f'bad MSZIP block magic {b[:2]!r}')
                    comp_size = struct.unpack_from('<H', b, 2)[0]
                    blk = b[4:4 + comp_size]
                    out = zlib.decompressobj(-15)
                    data += out.decompress(blk)
                    b = b[4 + comp_size:]
                buf += data
            else:
                raise NotImplementedError(f'compress cfg={cfg}')
        fo['buf'] = buf
        print(f'folder {idx}: cfg={cfg} inflated={len(buf):,}')

    # 文件表
    c_off = coffFiles
    written = 0
    for i in range(cFiles):
        cbFile, uoffFolderStart, iFolder, date, time, attribs = CFFILE.unpack_from(d, c_off)
        e = d.index(b'\x00', c_off + CFFILE.size)
        name = d[c_off + CFFILE.size:e].decode('cp1252', 'replace')
        c_off = e + 1
        if not name:
            continue
        buf = folders[iFolder]['buf']
        blob = bytes(buf[uoffFolderStart:uoffFolderStart + cbFile])
        out = os.path.join(outdir, name.lstrip('\\').replace('\\', '/'))
        os.makedirs(os.path.dirname(out), exist_ok=True)
        open(out, 'wb').write(blob)
        written += 1
        print(f'{name:70s} {cbFile:>12,}')
    print(f'\n已写出 {written} 个文件 -> {outdir}')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
