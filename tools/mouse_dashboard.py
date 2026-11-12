#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mouse_dashboard.py — SecDisplay 鼠标速率与发送链路实时仪表盘

两部分数据合在一屏：
  1. mouseprobe 采样本机光标位置，算瞬时速度、移动事件率、是否在虚拟屏内
  2. 解析发送端日志，算光标包速率、发送帧率、在途、丢弃、编码延迟

用法:
    python3 tools/mouse_dashboard.py
    python3 tools/mouse_dashboard.py --simulate circle --seconds 20
    python3 tools/mouse_dashboard.py --log prototype/mac/logs/sender_20261112_193425.log
    python3 tools/mouse_dashboard.py --csv /tmp/mouse.csv

依赖: tools/mouseprobe（swiftc -O tools/MouseProbe.swift -o tools/mouseprobe）
"""

import argparse
import csv
import glob
import os
import re
import subprocess
import sys
import threading
import time
from collections import deque

METRIC_RE = re.compile(
    r"^\[(\d+\.\d+)\]\s*采集 (\d+)\s+峰值 (\d+)fps\s+空闲 (\d+)\s+发送 (\d+)\s+"
    r"光标\+(\d+)\s+图像\+(\d+)\s+输入 (\d+)\s+丢弃 (\d+)\s+([\d.]+) Mbps\s+"
    r"在途 (\d+)\s+采集延迟 ([\d.]+)\s+编码延迟 ([\d.]+) ms"
)

SPARK = "▁▂▃▄▅▆▇█"


def latest_sender_log():
    files = glob.glob("prototype/mac/logs/sender_*.log")
    if not files:
        return None
    return max(files, key=os.path.getmtime)


class LogTail:
    def __init__(self, path):
        self.path = path
        self.f = None
        self.buf = ""
        self.last = None
        self.history = deque(maxlen=600)
        self.probe_t = time.time()
        if path:
            self.f = open(path, "r", errors="replace")
            self.f.seek(0, os.SEEK_END)

    def poll(self):
        if not self.f:
            return
        chunk = self.f.read()
        if not chunk:
            return
        self.buf += chunk
        while "\n" in self.buf:
            line, self.buf = self.buf.split("\n", 1)
            m = METRIC_RE.match(line)
            if not m:
                continue
            now = time.time()
            dt = max(now - self.probe_t, 0.001)
            self.probe_t = now
            vals = m.groups()
            sample = {
                "t": now,
                "capture": int(vals[1]),
                "peak_fps": int(vals[2]),
                "sent": int(vals[4]),
                "cursor": int(vals[5]),
                "input": int(vals[7]),
                "drop": int(vals[8]),
                "mbps": float(vals[9]),
                "inflight": int(vals[10]),
                "cap_ms": float(vals[11]),
                "enc_ms": float(vals[12]),
                "cursor_rate": int(vals[5]) / dt,
                "send_rate": int(vals[4]) / dt,
            }
            prev = self.last
            if prev:
                sample["drop_delta"] = sample["drop"] - prev["drop"]
                sample["cursor_delta"] = sample["cursor"] - prev["cursor"]
                sample["send_delta"] = sample["sent"] - prev["sent"]
            else:
                sample["drop_delta"] = 0
                sample["cursor_delta"] = 0
                sample["send_delta"] = 0
            self.last = sample
            self.history.append(sample)


class Probe:
    def __init__(self, binary, simulate, seconds, speed, post=False):
        self.lines = deque(maxlen=2000)
        cmd = [binary]
        if simulate != "none":
            cmd += ["--simulate", simulate, "--seconds", str(seconds), "--speed", str(speed)]
        if post:
            cmd += ["--post"]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     text=True, bufsize=1)
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()

    def _read(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                t, x, y, v, eps, inside = line.split(",")
                self.lines.append({
                    "t": float(t), "x": float(x), "y": float(y),
                    "v": float(v), "eps": float(eps), "inside": int(inside),
                })
            except ValueError:
                continue

    def stop(self):
        try:
            self.proc.terminate()
        except Exception:
            pass


class Spark:
    def __init__(self, n=60):
        self.n = n
        self.vals = deque(maxlen=n)

    def add(self, v):
        self.vals.append(v)

    def render(self):
        if not self.vals:
            return ""
        mx = max(self.vals) or 1.0
        out = []
        for v in self.vals:
            idx = int((v / mx) * (len(SPARK) - 1))
            out.append(SPARK[max(0, min(len(SPARK) - 1, idx))])
        return "".join(out)


def clear():
    sys.stdout.write("\033[H\033[J")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default=None)
    ap.add_argument("--probe", default=None)
    ap.add_argument("--simulate", default="none")
    ap.add_argument("--seconds", type=float, default=0)
    ap.add_argument("--speed", type=float, default=600)
    ap.add_argument("--post", action="store_true",
                    help="用真实 mouseMoved 事件模拟，能触发发送端事件驱动路径")
    ap.add_argument("--csv", default=None)
    ap.add_argument("--no-clear", action="store_true")
    args = ap.parse_args()

    probe_bin = args.probe
    if not probe_bin:
        here = os.path.dirname(os.path.abspath(__file__))
        probe_bin = os.path.join(here, "mouseprobe")
    if not os.path.exists(probe_bin):
        print("缺少 %s，先编译: swiftc -O tools/MouseProbe.swift -o tools/mouseprobe" % probe_bin)
        return 1

    log_path = args.log or latest_sender_log()
    log = LogTail(log_path)
    probe = Probe(probe_bin, args.simulate, args.seconds, args.speed, args.post)

    csv_f = None
    csv_w = None
    if args.csv:
        csv_f = open(args.csv, "w", newline="")
        csv_w = csv.writer(csv_f)
        csv_w.writerow(["t_ms", "x", "y", "speed_px_s", "moves_per_s", "inside",
                        "cursor_rate", "send_rate", "enc_ms", "cap_ms", "inflight", "drop"])

    speed_spark = Spark(60)
    last_spark = time.time()
    last_v = 0.0
    smooth_v = 0.0
    last_eps = 0.0
    inside = 0
    pos = (0.0, 0.0)
    sent_total = 0
    cursor_total = 0
    drop_total = 0
    all_speeds = []
    last_probe_t = None

    t_start = time.time()
    try:
        while True:
            log.poll()
            if probe.lines:
                s = probe.lines[-1]
                if last_probe_t is None or s["t"] > last_probe_t:
                    last_probe_t = s["t"]
                    pos = (s["x"], s["y"])
                    last_v = s["v"]
                    last_eps = s["eps"]
                    inside = s["inside"]
                    smooth_v = smooth_v * 0.7 + last_v * 0.3
                    all_speeds.append(last_v)
                    if len(all_speeds) > 12000:
                        all_speeds.pop(0)
                    if csv_w:
                        ls = log.last or {}
                        csv_w.writerow([s["t"], s["x"], s["y"], s["v"], s["eps"], s["inside"],
                                        ls.get("cursor_rate", 0), ls.get("send_rate", 0),
                                        ls.get("enc_ms", 0), ls.get("cap_ms", 0),
                                        ls.get("inflight", 0), ls.get("drop", 0)])
                        csv_f.flush()

            if time.time() - last_spark >= 1.0:
                speed_spark.add(smooth_v)
                last_spark = time.time()

            ls = log.last or {}
            if ls:
                sent_total = ls.get("sent", sent_total)
                cursor_total = ls.get("cursor", cursor_total)
                drop_total = ls.get("drop", drop_total)

            if not args.no_clear:
                clear()
            elapsed = time.time() - t_start
            print("SecDisplay 鼠标速率仪表盘   %s   运行 %ds" %
                  (time.strftime("%H:%M:%S"), int(elapsed)))
            print("─" * 68)
            print("光标   (%7.1f, %6.1f)   %s" %
                  (pos[0], pos[1], "在虚拟屏内" if inside else "主屏/其他屏"))
            print("瞬时   %8.1f px/s     平滑 %8.1f px/s" % (last_v, smooth_v))
            print("移动   %8.1f 次/秒" % last_eps)
            print()
            print("速度 60s  " + speed_spark.render())
            print()
            print("发送端   " + (log_path or "未找到日志"))
            print("光标包  %7.1f /s      发送 %6.1f fps      在途 %d" %
                  (ls.get("cursor_rate", 0), ls.get("send_rate", 0), ls.get("inflight", 0)))
            print("编码    %7.1f ms      采集 %6.1f ms      码率 %.1f Mbps" %
                  (ls.get("enc_ms", 0), ls.get("cap_ms", 0), ls.get("mbps", 0)))
            print("累计    发送 %d   光标包 %d   丢弃 %d" % (sent_total, cursor_total, drop_total))
            print()
            print("Ctrl-C 结束" + ("，数据写 %s" % args.csv if args.csv else ""))
            sys.stdout.flush()
            time.sleep(0.2)
    except KeyboardInterrupt:
        pass
    finally:
        probe.stop()
        if csv_f:
            csv_f.close()
        if all_speeds:
            all_speeds.sort()
            n = len(all_speeds)
            p50 = all_speeds[n // 2]
            p95 = all_speeds[min(n - 1, int(n * 0.95))]
            print("\n汇总: 采样 %d 个窗口, 速度 p50 %.0f px/s, p95 %.0f px/s, 峰值 %.0f px/s" %
                  (n, p50, p95, all_speeds[-1]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
