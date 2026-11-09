#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SecDisplay 运行日志 -> 脱敏指标 JSON。

设计约束（仓库公开）：
  * 只输出「解析后的数字」与「固定枚举字符串」。
  * 绝不复制任何原始日志行；不输出 IP、端口、endpoint、主机名、
    窗口标题、文件路径、用户名、日志正文。
  * 输出字段白名单，新增字段必须在这里显式登记。

用法：
  python3 extract_telemetry.py --platform mac --log <log> --out <json> [--commit <hash>]
  python3 extract_telemetry.py --platform win --log <log> --out <json> [--commit <hash>]

Windows 端若没有 Python，用 extract_telemetry.ps1（输出同一 schema）。
"""
import argparse
import json
import os
import re
import statistics
import sys
from datetime import datetime, timezone

SCHEMA = 1


def read_text(path):
    with open(path, "rb") as fh:
        return fh.read().decode("utf-8", errors="ignore")


def r2(x):
    return round(float(x), 2)


def agg(nums):
    """数值数组的 min / median / p95 / max。"""
    if not nums:
        return None
    s = sorted(nums)
    n = len(s)
    p95 = s[min(n - 1, int(0.95 * (n - 1)))]
    return {
        "min": r2(s[0]),
        "median": r2(statistics.median(s)),
        "p95": r2(p95),
        "max": r2(s[-1]),
    }


def last(nums):
    return r2(nums[-1]) if nums else None


def total(nums):
    return int(sum(nums)) if nums else 0


def ints(pattern, text):
    return [int(v) for v in re.findall(pattern, text)]


def floats(pattern, text):
    return [float(v) for v in re.findall(pattern, text)]


def stat_lines(text, marker):
    return [ln for ln in text.splitlines() if marker in ln]


def parse_mac(text):
    stat = stat_lines(text, "峰值")
    # 只在统计行上取值，避免别的日志里的数字混进来
    blob = "\n".join(ln for ln in stat if "采集" in ln)

    peak = floats(r"峰值\s+([\d.]+)\s*fps", blob)
    cap = floats(r"采集延迟\s+([\d.]+)", blob)
    enc = floats(r"编码延迟\s+([\d.]+)", blob)
    mbps = floats(r"([\d.]+)\s*Mbps", blob)
    send = ints(r"发送\s+(\d+)", blob)
    cursor = ints(r"光标\+\s*(\d+)", blob)
    inp = ints(r"输入\s+(\d+)", blob)
    drop = ints(r"丢弃\s+(\d+)", blob)
    inflight = ints(r"在途\s+(\d+)", blob)
    idle = ints(r"空闲\s+(\d+)", blob)

    coord_w = coord_h = None
    m = re.search(r"坐标基准:\s*逻辑点\s*(\d+)x(\d+)", text)
    if m:
        coord_w, coord_h = int(m.group(1)), int(m.group(2))

    video_w = video_h = cap_hz = None
    m = re.search(r"虚拟屏就绪\s*id=\d+\s*(\d+)x(\d+)", text)
    if m:
        video_w, video_h = int(m.group(1)), int(m.group(2))
    m = re.search(r"采集上限\s*(\d+)\s*fps", text)
    if m:
        cap_hz = int(m.group(1))

    # 字符串字段一律走白名单，绝不把日志里的任意 \S+ 带进公开仓
    preset = variant = None
    m = re.search(r"使用预设档位:\s*([A-Za-z]+)", text)
    if m and m.group(1) in ("sharp", "balanced", "smooth", "fast"):
        preset = m.group(1)
    m = re.search(r"编码参数方案\s*([A-Za-z0-9]{1,4})", text)
    if m:
        variant = m.group(1)

    warnings, counts = [], {}
    if "未获得辅助功能权限" in text:
        warnings.append("ax_not_trusted")
    if "需要屏幕录制权限" in text:
        warnings.append("screen_recording_missing")
    if "虚拟屏创建失败" in text or "创建被拒绝" in text:
        warnings.append("vdisplay_create_failed")
    n_rebuild = len(re.findall(r"抓屏.*?重建", text))
    if n_rebuild:
        warnings.append("stream_rebuild")
        counts["stream_rebuild"] = n_rebuild
    n_congest = len(re.findall(r"网络拥塞", text))
    if n_congest:
        warnings.append("congestion")
        counts["congestion"] = n_congest

    return {
        "coord": {"logical_w": coord_w, "logical_h": coord_h},
        "config": {
            "video_w": video_w, "video_h": video_h,
            "capture_hz": cap_hz, "preset": preset,
            "encoder_variant": variant,
        },
        "samples": len(stat),
        "metrics": {
            "peak_fps": agg(peak),
            "capture_ms": agg(cap),
            "encode_ms": agg(enc),
            "mbps": agg(mbps),
            "sent_per_sample": agg(send),
            "cursor_pkts_total": total(cursor),
            "input_pkts_total": total(inp),
            "dropped_total": total(drop),
            "inflight_max": max(inflight) if inflight else None,
            "idle_last": last(idle),
        },
        "warnings": warnings,
        "warning_counts": counts,
    }


def parse_win(text):
    # 与 extract_telemetry.ps1 的正则保持一致
    stat = stat_lines(text, "附加延迟")
    blob = "\n".join(stat)

    packets = ints(r"包\s+(\d+)", blob)
    decoded = ints(r"解码\s+(\d+)\(\+\d+\)", blob)
    dec_inc = ints(r"解码\s+\d+\(\+(\d+)\)", blob)
    mbps = floats(r"([\d.]+)\s*Mbps", blob)
    extra = floats(r"附加延迟\s+([\d.]+)\s*ms", blob)
    fails = ints(r"解码失败\s+(\d+)", blob)

    lw = lh = pw = ph = coord_source = None
    m = re.search(r"坐标基准:\s*逻辑\s*(\d+)x(\d+)（物理\s*(\d+)x(\d+)", text)
    if m:
        lw, lh = int(m.group(1)), int(m.group(2))
        pw, ph = int(m.group(3)), int(m.group(4))
    if "命令行指定" in text:
        coord_source = "explicit"
    elif "自动 2x" in text:
        coord_source = "auto2x"

    present_mode = None
    if "呈现方式: 垂直同步" in text:
        present_mode = "vsync"
    elif "呈现方式: 免同步" in text:
        present_mode = "tearing"

    decoder_hw = None
    m = re.search(r"解码器就绪\s*\d+x\d+（(硬件|软件)）", text)
    if m:
        decoder_hw = (m.group(1) == "硬件")

    client_w = client_h = None
    m = re.search(r"窗口客户区\s*(\d+)x(\d+)", text)
    if m:
        client_w, client_h = int(m.group(1)), int(m.group(2))

    fullscreen = ("已切换到全屏" in text) or ("全屏目标尺寸" in text)

    warnings = []
    if fails and max(fails) > 0:
        warnings.append("decode_fail")
    if "没有解码器接受 D3D 管理器" in text or "退回软件解码" in text:
        warnings.append("software_decode")
    if "窗口创建失败" in text:
        warnings.append("window_create_failed")
    if "连接失败" in text:
        warnings.append("connect_failed")

    return {
        "coord": {
            "logical_w": lw, "logical_h": lh,
            "physical_w": pw, "physical_h": ph,
            "source": coord_source,
        },
        "status": {
            "present_mode": present_mode,
            "decoder_hw": decoder_hw,
            "client_w": client_w, "client_h": client_h,
            "fullscreen": fullscreen,
        },
        "samples": len(stat),
        "metrics": {
            "packets_last": last(packets),
            "decoded_last": last(decoded),
            "decoded_per_sample": agg(dec_inc),
            "decode_fail_last": last(fails),
            "mbps": agg(mbps),
            "extra_latency_ms": agg(extra),
        },
        "warnings": warnings,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", required=True, choices=["mac", "win"])
    ap.add_argument("--log", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--commit", default="unknown")
    a = ap.parse_args()

    if not os.path.isfile(a.log):
        print("日志文件不存在: " + a.log, file=sys.stderr)
        return 1

    text = read_text(a.log)
    body = parse_mac(text) if a.platform == "mac" else parse_win(text)
    doc = {
        "schema": SCHEMA,
        "platform": a.platform,
        "generated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "commit": str(a.commit)[:12],
    }
    doc.update(body)

    outdir = os.path.dirname(os.path.abspath(a.out))
    os.makedirs(outdir, exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print("wrote " + a.out + " samples=" + str(body["samples"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
