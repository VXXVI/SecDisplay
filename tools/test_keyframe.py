#!/usr/bin/env python3
"""测试关键帧请求链路。

连上 Mac 发送端，发 0x02 请求关键帧，然后解析回来的帧，
检查是否在合理时间内收到带 SPS/PPS 的关键帧。
"""
import socket, struct, sys, time

HOST = "127.0.0.1"
PORT = 9922
TYPE_VIDEO = 0x01
TYPE_KEYFRAME_REQUEST = 0x02


def split_avcc(data):
    """把 AVCC 切成 NAL 列表"""
    nals = []
    i = 0
    while i + 4 <= len(data):
        n = struct.unpack(">I", data[i:i+4])[0]
        i += 4
        if n == 0 or i + n > len(data):
            break
        nals.append(data[i:i+n])
        i += n
    return nals


def nal_type(nal):
    return nal[0] & 0x1F if nal else -1


def main():
    print(f"连接 {HOST}:{PORT}")
    s = socket.create_connection((HOST, PORT), timeout=5)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    print("已连接")

    # 立刻请求关键帧
    s.sendall(bytes([TYPE_KEYFRAME_REQUEST]))
    print("已发送 0x02 关键帧请求")
    t0 = time.time()

    frames = 0
    keyframes = 0
    first_key_at = None
    total_bytes = 0
    deadline = t0 + 10.0

    buf = b""
    while time.time() < deadline:
        s.settimeout(2.0)
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            print("对端关闭")
            break
        buf += chunk

        while len(buf) >= 4:
            ln = struct.unpack(">I", buf[:4])[0]
            if len(buf) < 4 + ln:
                break
            body = buf[4:4+ln]
            buf = buf[4+ln:]

            if body[0] != TYPE_VIDEO:
                continue
            ts = struct.unpack(">Q", body[1:9])[0]
            payload = body[9:]
            nals = split_avcc(payload)
            types = [nal_type(n) for n in nals]

            frames += 1
            total_bytes += len(payload)

            is_key = 7 in types and 8 in types
            if is_key:
                keyframes += 1
                if first_key_at is None:
                    first_key_at = time.time() - t0

            if frames <= 6 or is_key:
                dt = (time.time() - t0) * 1000
                tag = "关键帧" if is_key else "      "
                print(f"  [{dt:7.1f}ms] 帧{frames:3d} {tag} NAL类型={types} {len(payload)}字节")

    el = time.time() - t0
    print(f"\n===== 结果 =====")
    print(f"时长 {el:.1f}s  收到 {frames} 帧  其中关键帧 {keyframes} 个")
    if first_key_at is not None:
        print(f"首个关键帧延迟 {first_key_at*1000:.0f} ms")
    else:
        print("!! 没有收到关键帧 !!")
    if frames:
        print(f"码率 {total_bytes*8/el/1e6:.1f} Mbps")
    s.close()
    return 0 if keyframes > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
