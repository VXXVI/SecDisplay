#!/usr/bin/env python3
"""接收 Windows 端 fetch-duet.ps1 传来的 zip，解包到 tools/_duet_bin/。

协议：[8 字节小端长度][zip 数据]
用法：python3 tools/recv-duet.py            # 前台等待一次
      python3 tools/recv-duet.py --serve    # 循环接收，可反复重传
"""
import argparse
import os
import socket
import struct
import sys
import zipfile

HOST = "0.0.0.0"
PORT = 9933
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_duet_bin")


def recv_one(conn):
    def readn(n):
        buf = b""
        while len(buf) < n:
            chunk = conn.recv(min(65536, n - len(buf)))
            if not chunk:
                raise ConnectionError("连接提前关闭")
            buf += chunk
        return buf

    (size,) = struct.unpack("<q", readn(8))
    if size <= 0 or size > 2 * 1024 * 1024 * 1024:
        raise ValueError(f"长度异常: {size}")
    print(f"接收 {size/1024/1024:.2f} MB ...", flush=True)
    data = readn(size)

    tmp = OUT + ".zip"
    with open(tmp, "wb") as f:
        f.write(data)

    os.makedirs(OUT, exist_ok=True)
    with zipfile.ZipFile(tmp) as z:
        names = [n for n in z.namelist() if not n.endswith("/")]
        for i, n in enumerate(names):
            # 去掉路径里的盘符和上级目录，防解压穿越
            safe = n.replace("\\", "/").lstrip("/")
            safe = "/".join(p for p in safe.split("/") if p not in ("..", ""))
            dest = os.path.join(OUT, safe)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with z.open(n) as src, open(dest, "wb") as dst:
                dst.write(src.read())
            if i % 20 == 0:
                print(f"  {i+1}/{len(names)}", flush=True)
    print(f"解包完成: {OUT} 共 {len(names)} 个文件", flush=True)
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--serve", action="store_true", help="循环接收，不退出")
    args = ap.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(1)
    print(f"监听 {PORT}，等待 Windows 传文件 ... (Ctrl-C 退出)", flush=True)

    while True:
        conn, addr = srv.accept()
        print(f"连接来自 {addr[0]}", flush=True)
        try:
            with conn:
                recv_one(conn)
        except Exception as e:
            print(f"接收失败: {e}", file=sys.stderr, flush=True)
        if not args.serve:
            break
        print("继续等待下一次 ...", flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n已停止")
