#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
latency_dashboard.py — SecDisplay 发送端延迟/卡顿仪表盘（Python 3.9 标准库，零第三方依赖）

实时解析发送端日志（prototype/mac/logs/sender_*.log），统计采集/编码延迟、帧率、
丢帧、在途积压、码率调整，检测卡顿，输出终端表格 + CSV + 自包含 HTML 报告。

用法示例：
    python3 tools/latency_dashboard.py --log prototype/mac/logs/sender_20261111_214104.log

常用参数：
    --log PATH              日志文件，缺省取 logs 目录里最新的 sender_*.log
    --follow                跟随模式：读到 EOF 后继续 tail，实时刷新终端表格（Ctrl-C 结束并出报告）
    --interval N            跟随模式终端刷新间隔秒数（默认 5）
    --window N              统计窗口秒数（默认 60）
    --csv PATH              CSV 输出路径（默认 research/latency_dashboard_<时间戳>.csv）
    --html PATH             HTML 报告输出路径（默认 research/latency_report_<时间戳>.html）
    --with-latencyclient [SECS] [HOST]
                            同时启动 tools/latencyclient 测端到端延迟，结束后解析其中位/p95/最大
    --low-fps N             判定低帧率的阈值（默认 15 fps）
    --enc-lat N             判定编码延迟过高的阈值 ms（默认 50）

无 --follow 时：读完整个日志（流式逐行，不整读进内存），打印统计、落 CSV 和 HTML 后退出，
适合回放历史日志。

数据行格式（ScreenSender.swift 每 2s 打一行）：
    [时间] 采集 N  峰值 Nfps  空闲 N  发送 N  光标+N  图像+N  输入 N  丢弃 N  X.X Mbps  在途 N  采集延迟 X.X  编码延迟 X.X ms
注意：采集 N 与丢弃 N 是进程启动以来的累计值，脚本内部换算成每窗口增量再算帧率。
"""

import argparse
import csv
import glob
import os
import re
import signal
import subprocess
import sys
import time
from collections import deque

# ---------- 日志解析 ----------

METRIC_RE = re.compile(
    r"^\[(\d+\.\d+)\]\s*采集 (\d+)\s+峰值 (\d+)fps\s+空闲 (\d+)\s+发送 (\d+)\s+"
    r"光标\+(\d+)\s+图像\+(\d+)\s+输入 (\d+)\s+丢弃 (\d+)\s+([\d.]+) Mbps\s+"
    r"在途 (\d+)\s+采集延迟 ([\d.]+)\s+编码延迟 ([\d.]+) ms"
)
BITRATE_RE = re.compile(r"^\[(\d+\.\d+)\]\s*(.+?)码率(?:下调|上调|回升)至 (\d+) Mbps")
LC_PATTERNS = {
    "samples": re.compile(r"样本 (\d+) 帧"),
    "p50": re.compile(r"中位 ([\d.]+) ms"),
    "p95": re.compile(r"p95\s+([\d.]+) ms"),
    "max": re.compile(r"最大 ([\d.]+) ms"),
    "stalls": re.compile(r"明显停顿\S* (\d+) 次"),
}


class Sample(object):
    __slots__ = ("ts", "captured", "peak_fps", "idle", "sent", "cursor", "image",
                 "inputs", "dropped", "mbps", "inflight", "cap_lat", "enc_lat",
                 "cap_delta", "dropped_delta")

    def __init__(self, m):
        (self.ts, self.captured, self.peak_fps, self.idle, self.sent, self.cursor,
         self.image, self.inputs, self.dropped, self.mbps, self.inflight,
         self.cap_lat, self.enc_lat) = (
            float(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)),
            int(m.group(5)), int(m.group(6)), int(m.group(7)), int(m.group(8)),
            int(m.group(9)), float(m.group(10)), int(m.group(11)),
            float(m.group(12)), float(m.group(13)))


class BitrateEvent(object):
    __slots__ = ("ts", "reason", "mbps", "direction")

    def __init__(self, ts, reason, mbps):
        self.ts, self.reason, self.mbps = ts, reason.strip("，, "), int(mbps)
        self.direction = "down" if ("下调" in reason or "健康度" in reason) else "up"


class StutterEvent(object):
    def __init__(self, ts, kind, detail):
        self.ts, self.kind, self.detail = ts, kind, detail


def percentile(sorted_vals, p):
    if not sorted_vals:
        return 0.0
    idx = int(round(p * (len(sorted_vals) - 1)))
    return sorted_vals[idx]


# ---------- 主状态 ----------

class Dashboard(object):
    def __init__(self, args):
        self.args = args
        self.samples = deque()          # 全部样本（每 2s 一条，10 小时也才 1.8 万条，可接受）
        self.bitrate_events = []
        self.stutter_events = []
        self.last_captured = None
        self.last_dropped = None
        self.low_fps_run = 0            # 连续低帧率计数
        self.low_fps_start = None
        self.total_bytes_lines = 0
        self.lc_result = None           # latencyclient 解析结果 dict
        self.start_wall = time.time()

    # --- 逐行处理 ---
    def feed_line(self, line):
        line = line.strip()
        if not line:
            return
        self.total_bytes_lines += 1
        m = METRIC_RE.match(line)
        if m:
            self._on_sample(Sample(m))
            return
        m = BITRATE_RE.match(line)
        if m:
            ev = BitrateEvent(float(m.group(1)), m.group(2), m.group(3))
            self.bitrate_events.append(ev)
            self.stutter_events.append(StutterEvent(
                ev.ts,
                "码率下调" if ev.direction == "down" else "码率回升",
                "%s → %d Mbps" % (ev.reason, ev.mbps)))

    def _on_sample(self, s):
        # 时间戳回跳超过 5 秒说明是新一次运行（日志被追加，时间基准变了）：
        # 重置全部统计，报告只覆盖最新会话
        if self.samples and s.ts < self.samples[-1].ts - 5.0:
            self.samples.clear()
            del self.bitrate_events[:]
            del self.stutter_events[:]
            self.last_captured = None
            self.last_dropped = None
            self.low_fps_run = 0
            self.low_fps_start = None
        cap_delta = dropped_delta = 0
        if self.last_captured is not None:
            cap_delta = max(0, s.captured - self.last_captured)
            dropped_delta = max(0, s.dropped - self.last_dropped)
        self.last_captured, self.last_dropped = s.captured, s.dropped
        s.cap_delta, s.dropped_delta = cap_delta, dropped_delta  # 动态挂两个属性
        self.samples.append(s)

        fps = cap_delta / 2.0
        activity = s.sent + s.image + s.cursor
        # 丢帧事件
        if dropped_delta > 0 and self.args and hasattr(self.args, "low_fps"):
            self.stutter_events.append(StutterEvent(s.ts, "丢帧", "+%d 帧" % dropped_delta))
        # 在途积压
        if s.inflight >= 2:
            self.stutter_events.append(StutterEvent(s.ts, "在途积压", "inFlight=%d" % s.inflight))
        # 编码延迟过高
        if s.enc_lat >= self.args.enc_lat:
            self.stutter_events.append(StutterEvent(s.ts, "编码延迟高", "%.1f ms" % s.enc_lat))
        # 连续低帧率段（有内容活动才算）
        if activity > 0 and 0 < fps < self.args.low_fps:
            if self.low_fps_run == 0:
                self.low_fps_start = s.ts
            self.low_fps_run += 1
        else:
            if self.low_fps_run >= 2:
                self.stutter_events.append(StutterEvent(
                    self.low_fps_start, "连续低帧率",
                    "%d 个采样窗 fps<%d（约 %.0f 秒）" % (self.low_fps_run, self.args.low_fps,
                                                        self.low_fps_run * 2.0)))
            self.low_fps_run = 0

    def finish_lowfps(self):
        if self.low_fps_run >= 2:
            self.stutter_events.append(StutterEvent(
                self.low_fps_start, "连续低帧率",
                "%d 个采样窗 fps<%d（约 %.0f 秒）" % (self.low_fps_run, self.args.low_fps,
                                                    self.low_fps_run * 2.0)))
        self.low_fps_run = 0

    # --- 窗口统计 ---
    def window_stats(self, window_s):
        if not self.samples:
            return None
        t_end = self.samples[-1].ts
        ws = [s for s in self.samples if t_end - s.ts <= window_s]
        if not ws:
            return None
        cap_l = sorted(s.cap_lat for s in ws if s.cap_lat > 0)
        enc_l = sorted(s.enc_lat for s in ws if s.enc_lat > 0)
        span = max(ws[-1].ts - ws[0].ts, 2.0)
        total_cap = sum(s.cap_delta for s in ws)
        total_drop = sum(s.dropped_delta for s in ws)
        total_sent = sum(s.sent for s in ws)
        inflight_hits = sum(1 for s in ws if s.inflight >= 2)
        return {
            "n": len(ws),
            "t0": ws[0].ts, "t1": ws[-1].ts,
            "cap_lat": (percentile(cap_l, 0.50), percentile(cap_l, 0.95),
                        percentile(cap_l, 0.99), max(cap_l) if cap_l else 0.0),
            "enc_lat": (percentile(enc_l, 0.50), percentile(enc_l, 0.95),
                        percentile(enc_l, 0.99), max(enc_l) if enc_l else 0.0),
            "cap_lat_mean": sum(cap_l) / len(cap_l) if cap_l else 0.0,
            "enc_lat_mean": sum(enc_l) / len(enc_l) if enc_l else 0.0,
            "fps_avg": total_cap / span,
            "peak_fps": max(s.peak_fps for s in ws),
            "captured": total_cap, "sent": total_sent, "dropped": total_drop,
            "drop_rate": total_drop / max(total_cap, 1) * 100.0,
            "inflight_hits": inflight_hits,
            "mbps_last": ws[-1].mbps,
            "mbps_avg": sum(s.mbps for s in ws) / len(ws),
            "bitrate_last": self.bitrate_events[-1].mbps if self.bitrate_events else None,
        }

    # --- 终端表格 ---
    def render_table(self, window_s):
        st = self.window_stats(window_s)
        out = []
        out.append("=" * 78)
        out.append("SecDisplay 延迟/卡顿仪表盘   窗口 %ds   样本行 %d   %s" %
                   (window_s, self.total_bytes_lines,
                    time.strftime("%H:%M:%S")))
        out.append("=" * 78)
        if st is None:
            out.append("（还没有解析到数据行，等待发送端输出…）")
            return "\n".join(out)
        cl, el = st["cap_lat"], st["enc_lat"]
        out.append("%-14s %10s %10s %10s %10s" % ("延迟(ms)", "p50", "p95", "p99", "max"))
        out.append("%-14s %10.1f %10.1f %10.1f %10.1f" % ("  采集延迟", cl[0], cl[1], cl[2], cl[3]))
        out.append("%-14s %10.1f %10.1f %10.1f %10.1f" % ("  编码延迟", el[0], el[1], el[2], el[3]))
        out.append("-" * 78)
        out.append("窗口帧率(采集) %5.1f fps   峰值 %d fps   发送 %d 帧   采集 %d 帧   丢弃 %d (%.1f%%)"
                   % (st["fps_avg"], st["peak_fps"], st["sent"], st["captured"],
                      st["dropped"], st["drop_rate"]))
        out.append("实际码率 %.1f Mbps(均) / %.1f Mbps(末)   目标码率 %s   在途积压窗口内 %d 次"
                   % (st["mbps_avg"], st["mbps_last"],
                      ("%d Mbps" % st["bitrate_last"]) if st["bitrate_last"] else "n/a",
                      st["inflight_hits"]))
        # 最近事件
        recent = [e for e in self.stutter_events if st["t1"] - e.ts <= window_s]
        out.append("-" * 78)
        if recent:
            out.append("最近 %ds 卡顿/事件（全时段 %d 条）："
                       % (window_s, len(self.stutter_events)))
            for e in recent[-8:]:
                out.append("  [%+.1fs] %-8s %s" % (e.ts - self.samples[0].ts, e.kind, e.detail))
        else:
            out.append("最近 %ds 无卡顿事件（全时段 %d 条）" % (window_s, len(self.stutter_events)))
        if self.lc_result:
            lc = self.lc_result
            out.append("-" * 78)
            out.append("端到端延迟(latencyclient)：样本 %s 帧  p50 %s ms  p95 %s ms  最大 %s ms  明显停顿 %s 次"
                       % (lc.get("samples", "?"), lc.get("p50", "?"),
                          lc.get("p95", "?"), lc.get("max", "?"), lc.get("stalls", "?")))
        out.append("Ctrl-C 结束并生成 HTML 报告")
        return "\n".join(out)

    # --- CSV ---
    def write_csv(self, path):
        with open(path, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["ts", "captured", "cap_delta", "fps_2s", "peak_fps", "idle",
                        "sent", "cursor", "image", "inputs", "dropped_delta",
                        "mbps", "inflight", "cap_lat_ms", "enc_lat_ms"])
            for s in self.samples:
                w.writerow(["%.3f" % s.ts, s.captured, s.cap_delta,
                            "%.1f" % (s.cap_delta / 2.0), s.peak_fps, s.idle,
                            s.sent, s.cursor, s.image, s.inputs, s.dropped_delta,
                            "%.1f" % s.mbps, s.inflight,
                            "%.1f" % s.cap_lat, "%.1f" % s.enc_lat])

    # --- HTML ---
    def write_html(self, path):
        t0 = self.samples[0].ts if self.samples else 0.0
        series = [
            ("采集延迟 ms", [(s.ts - t0, s.cap_lat) for s in self.samples], "#2563eb"),
            ("编码延迟 ms", [(s.ts - t0, s.enc_lat) for s in self.samples], "#dc2626"),
            ("采集帧率 fps", [(s.ts - t0, s.cap_delta / 2.0) for s in self.samples], "#059669"),
            ("实际码率 Mbps", [(s.ts - t0, s.mbps) for s in self.samples], "#7c3aed"),
        ]
        svgs = [svg_chart(title, pts,
                          [StutterEvent(e.ts - t0, "", "") for e in self.stutter_events],
                          color)
                for title, pts, color in series]
        ev_rows = "".join(
            "<tr><td>%+.1fs</td><td>%s</td><td>%s</td></tr>" %
            (e.ts - t0, e.kind, e.detail) for e in self.stutter_events)
        br_rows = "".join(
            "<tr><td>%+.1fs</td><td>%s</td><td>%d Mbps</td></tr>" %
            (e.ts - t0, e.reason, e.mbps) for e in self.bitrate_events)
        st = self.window_stats(1e18)  # 全时段
        lc_html = ""
        if self.lc_result:
            lc = self.lc_result
            lc_html = ("<h2>端到端延迟（latencyclient）</h2><table><tr><th>样本帧</th><th>p50</th>"
                       "<th>p95</th><th>最大</th><th>明显停顿</th></tr><tr><td>%s</td><td>%s ms</td>"
                       "<td>%s ms</td><td>%s ms</td><td>%s</td></tr></table>"
                       % (lc.get("samples", "-"), lc.get("p50", "-"), lc.get("p95", "-"),
                          lc.get("max", "-"), lc.get("stalls", "-")))
        drop_total = st["dropped"] if st else 0
        doc = """<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">
<title>SecDisplay 延迟报告</title><style>
body{font-family:-apple-system,'PingFang SC',sans-serif;max-width:1240px;margin:24px auto;color:#111}
h1{font-size:22px} h2{font-size:17px;margin-top:28px}
table{border-collapse:collapse;font-size:13px;margin:8px 0}
td,th{border:1px solid #ddd;padding:4px 10px;text-align:left}
.summary{background:#f6f7f9;padding:10px 14px;border-radius:6px;font-size:14px}
svg{background:#fff;border:1px solid #e5e7eb;border-radius:4px}
</style></head><body>
<h1>SecDisplay 延迟/卡顿报告</h1>
<div class="summary">
生成时间 %s　样本 %d 行（约 %.0f 秒）　卡顿事件 %d 条　丢帧合计 %d 帧<br>
用法：<code>python3 tools/latency_dashboard.py --log prototype/mac/logs/&lt;日志文件&gt;</code>
</div>
<h2>时序图（红竖线 = 卡顿/码率事件）</h2>
%s
%s
<h2>卡顿事件</h2>
<table><tr><th>相对时间</th><th>类型</th><th>详情</th></tr>%s</table>
<h2>码率调整</h2>
<table><tr><th>相对时间</th><th>原因</th><th>目标码率</th></tr>%s</table>
</body></html>""" % (
            time.strftime("%Y-%m-%d %H:%M:%S"), self.total_bytes_lines,
            (self.samples[-1].ts - t0) if self.samples else 0.0,
            len(self.stutter_events), drop_total,
            "".join(svgs), lc_html, ev_rows or "<tr><td colspan=3>无</td></tr>",
            br_rows or "<tr><td colspan=3>无</td></tr>")
        with open(path, "w", encoding="utf-8") as f:
            f.write(doc)


# ---------- SVG ----------

def svg_chart(title, pts, events, color, width=1200, height=170):
    if not pts:
        return "<p>（%s：无数据）</p>" % title
    # 降采样到最多 600 点
    if len(pts) > 600:
        step = len(pts) / 600.0
        pts = [pts[int(i * step)] for i in range(600)]
    pad_l, pad_t, pad_b = 46, 14, 20
    w = width - pad_l - 10
    h = height - pad_t - pad_b
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    x0, x1 = min(xs), max(xs) or 1.0
    y1 = max(max(ys), 0.001)
    def X(t): return pad_l + (t - x0) / max(x1 - x0, 1e-9) * w
    def Y(v): return pad_t + h - v / y1 * h
    poly = " ".join("%.1f,%.1f" % (X(t), Y(v)) for t, v in pts)
    grid, labels = [], []
    for frac in (0, 0.5, 1.0):
        v = y1 * frac
        gy = Y(v)
        grid.append('<line x1="%d" y1="%.0f" x2="%d" y2="%.0f" stroke="#e5e7eb"/>' %
                    (pad_l, gy, width - 10, gy))
        labels.append('<text x="%d" y="%.0f" font-size="10" fill="#666" text-anchor="end">%.0f</text>'
                      % (pad_l - 5, gy + 3, v))
    # 事件竖线：横轴与 pts 一致，都是相对 t0 的秒数
    ev_lines = ""
    for e in events:
        ex = X(e.ts)
        ev_lines += ('<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" stroke="#dc2626" '
                     'stroke-opacity="0.35" stroke-width="1"/>' % (ex, pad_t, ex, pad_t + h))
    x_label = ('<text x="%d" y="%d" font-size="10" fill="#666">%.0fs</text>'
               % (width - 10, height - 4, x1))
    return ('<div><svg width="%d" height="%d" xmlns="http://www.w3.org/2000/svg">'
            '<text x="%d" y="11" font-size="12" fill="#111">%s</text>%s%s'
            '<polyline points="%s" fill="none" stroke="%s" stroke-width="1.4"/>%s%s'
            '</svg></div>') % (width, height, pad_l, title, "".join(grid), "".join(labels),
                               poly, color, ev_lines, x_label)


# ---------- latencyclient ----------

def run_latencyclient(secs, host):
    exe = os.path.join(os.path.dirname(os.path.abspath(__file__)), "latencyclient")
    if not os.path.exists(exe):
        print("[latencyclient] 未找到 %s，跳过端到端测量" % exe, file=sys.stderr)
        return None
    print("[latencyclient] 运行 %ss：%s" % (secs, exe), file=sys.stderr)
    try:
        p = subprocess.run([exe, str(secs), host], capture_output=True, timeout=secs + 30)
    except (subprocess.TimeoutExpired, OSError) as e:
        print("[latencyclient] 运行失败：%s" % e, file=sys.stderr)
        return None
    text = p.stderr.decode("utf-8", "replace")
    result = {}
    for key, pat in LC_PATTERNS.items():
        m = pat.search(text)
        if m:
            result[key] = m.group(1)
    return result or None


# ---------- 文件跟随 ----------

def iter_lines(path, follow, poll=0.5, stop=None):
    """流式逐行读取；follow 模式下读到 EOF 后继续等待新内容。不整读文件。
    stop 为可调用返回 True 时停止（让跟随模式能被 Ctrl-C 干净退出）。"""
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        while True:
            line = f.readline()
            if line:
                yield line
                continue
            if not follow or (stop is not None and stop()):
                return
            time.sleep(poll)


def newest_log():
    logs = sorted(glob.glob(os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "prototype", "mac", "logs",
        "sender_*.log")), key=os.path.getmtime)
    return logs[-1] if logs else None


def main():
    ap = argparse.ArgumentParser(description="SecDisplay 延迟/卡顿仪表盘")
    ap.add_argument("--log", help="发送端日志路径（默认取最新的 sender_*.log）")
    ap.add_argument("--follow", action="store_true", help="tail 跟随模式")
    ap.add_argument("--interval", type=float, default=5.0, help="刷新间隔秒（默认 5）")
    ap.add_argument("--window", type=float, default=60.0, help="统计窗口秒（默认 60）")
    ap.add_argument("--csv", help="CSV 输出路径")
    ap.add_argument("--html", help="HTML 报告路径")
    ap.add_argument("--with-latencyclient", nargs="?", const="10", default=None,
                    metavar="SECS[ HOST]", help="运行 latencyclient 测端到端延迟")
    ap.add_argument("--low-fps", type=float, default=15.0, help="低帧率阈值 fps")
    ap.add_argument("--enc-lat", type=float, default=50.0, help="编码延迟过高阈值 ms")
    args = ap.parse_args()

    log_path = args.log or newest_log()
    if not log_path or not os.path.exists(log_path):
        print("找不到日志文件：%s" % log_path, file=sys.stderr)
        return 2
    stamp = time.strftime("%Y%m%d_%H%M%S")
    csv_path = args.csv or os.path.join("research", "latency_dashboard_%s.csv" % stamp)
    html_path = args.html or os.path.join("research", "latency_report_%s.html" % stamp)

    dash = Dashboard(args)
    print("读取日志：%s%s" % (log_path, "（跟随模式，Ctrl-C 结束）" if args.follow else ""))
    if args.with_latencyclient:
        parts = args.with_latencyclient.split()
        secs = float(parts[0]) if parts else 10.0
        host = parts[1] if len(parts) > 1 else "127.0.0.1"
        dash.lc_result = run_latencyclient(secs, host)

    interrupted = {"flag": False}
    def on_sigint(_sig, _frm):
        interrupted["flag"] = True
    signal.signal(signal.SIGINT, on_sigint)

    last_render = 0.0
    for line in iter_lines(log_path, args.follow, stop=lambda: interrupted["flag"]):
        dash.feed_line(line)
        if args.follow and time.time() - last_render >= args.interval:
            last_render = time.time()
            sys.stdout.write("\x1b[2J\x1b[H" + dash.render_table(args.window) + "\n")
            sys.stdout.flush()
        if interrupted["flag"]:
            break
    dash.finish_lowfps()

    dash.write_csv(csv_path)
    dash.write_html(html_path)
    print(dash.render_table(args.window))
    print("\nCSV: %s\nHTML: %s" % (os.path.abspath(csv_path), os.path.abspath(html_path)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
