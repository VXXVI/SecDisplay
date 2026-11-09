#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CI 校验：脱敏输出里不得出现内网 IP / endpoint / 日志正文；字段齐全且数值合理。
用法: python3 tools/check_telemetry.py --mac <json> --win <json> --log <样本日志>
"""
import argparse
import json
import re
import sys

# 样本日志里出现过的敏感串，输出 JSON 里一个都不许有
FORBIDDEN = [
    "10.10.10.", "58392", "5839", "接收端已连接", "服务已启动",
    "警告:", "显示适配器", "端点", "SPS", "PPS", "hostname",
    "COMPUTERNAME", "USERNAME", "C:\\", "/Users/", "SecDisplay 接收端",
]


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def load(p):
    with open(p, "r", encoding="utf-8") as f:
        raw = f.read()
    return raw, json.loads(raw)


def check_doc(raw, doc, tag):
    for s in FORBIDDEN:
        if s in raw:
            fail("%s 输出里含有敏感串 %r" % (tag, s))
    for k in ("schema", "platform", "generated_utc", "commit", "coord", "samples", "metrics", "warnings"):
        if k not in doc:
            fail("%s 缺字段 %s" % (tag, k))
    if doc["schema"] != 1:
        fail("%s schema 应为 1" % tag)
    # 只许白名单字段，防止把原始行塞进新字段
    allowed = {"schema", "platform", "generated_utc", "commit", "coord", "config",
               "status", "samples", "metrics", "warnings", "warning_counts"}
    extra = set(doc.keys()) - allowed
    if extra:
        fail("%s 出现未登记字段 %s" % (tag, extra))

    # 结构性脱敏：所有叶子字符串必须落在固定枚举白名单里。
    # 这样即使日志将来冒出新的敏感串，被正则带出来也会在这里被拦下。
    STR_ENUM = {
        "mac", "win", "unknown", "auto2x", "explicit",
        "sharp", "balanced", "smooth", "fast", "A", "B", "C",
        "vsync", "tearing", "硬件", "软件",
        "ax_not_trusted", "screen_recording_missing", "vdisplay_create_failed",
        "stream_rebuild", "congestion", "decode_fail", "software_decode",
        "window_create_failed", "connect_failed",
        "generated_utc", "schema", "platform", "commit", "coord", "config",
        "status", "samples", "metrics", "warnings", "warning_counts",
        "source", "preset", "encoder_variant", "video_w", "video_h", "capture_hz",
        "logical_w", "logical_h", "physical_w", "physical_h", "present_mode",
        "decoder_hw", "client_w", "client_h", "fullscreen", "peak_fps",
        "capture_ms", "encode_ms", "mbps", "sent_per_sample", "min", "median",
        "p95", "max", "cursor_pkts_total", "input_pkts_total", "dropped_total",
        "inflight_max", "idle_last", "packets_last", "decoded_last",
        "decoded_per_sample", "decode_fail_last", "extra_latency_ms",
    }
    def walk(v, path=""):
        if isinstance(v, str):
            if v not in STR_ENUM and not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", v) \
               and v != doc.get("commit"):
                fail("%s 出现非白名单字符串 %r（路径 %s）" % (tag, v, path))
        elif isinstance(v, dict):
            for k, x in v.items():
                walk(x, path + "/" + str(k))
        elif isinstance(v, list):
            for i, x in enumerate(v):
                walk(x, path + "/[%d]" % i)
    walk(doc)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac", required=True)
    ap.add_argument("--win", required=True)
    ap.add_argument("--win-ps1", default=None)
    ap.add_argument("--log", required=True)
    a = ap.parse_args()

    rawm, m = load(a.mac)
    raww, w = load(a.win)
    check_doc(rawm, m, "mac")
    check_doc(raww, w, "win")

    # Windows 后备提取器必须与 Python 版字段级等价（generated_utc / commit 除外）
    if a.win_ps1:
        rawp, p = load(a.win_ps1)
        check_doc(rawp, p, "win-ps1")
        def strip(d):
            d = dict(d)
            d.pop("generated_utc", None)
            d.pop("commit", None)
            return d
        if strip(p) != strip(w):
            fail("PowerShell 提取器与 Python 版输出不一致")
        print("OK: PowerShell 后备提取器与 Python 版字段级一致")

    # 坐标基准必须抽出来且是 1440x900
    if (m["coord"].get("logical_w"), m["coord"].get("logical_h")) != (1440, 900):
        fail("mac 坐标基准解析错误: %s" % m["coord"])
    if (w["coord"].get("logical_w"), w["coord"].get("logical_h")) != (1440, 900):
        fail("win 坐标基准解析错误: %s" % w["coord"])
    if w["coord"].get("source") != "auto2x":
        fail("win 坐标来源解析错误")

    # 数值字段必须真的抽到了（不是全 None）
    if m["samples"] < 3:
        fail("mac 统计行不足")
    if not m["metrics"]["peak_fps"] or m["metrics"]["peak_fps"]["max"] < 40:
        fail("mac 峰值帧率解析错误")
    if not m["metrics"]["encode_ms"]:
        fail("mac 编码延迟解析错误")
    if w["samples"] < 3:
        fail("win 状态行不足")
    if not w["metrics"]["decoded_per_sample"]:
        fail("win 解码计数解析错误")
    if w["status"]["present_mode"] != "vsync":
        fail("win 呈现方式解析错误")
    if not m["warnings"] or "ax_not_trusted" not in m["warnings"]:
        fail("mac 权限告警没抽到")

    # commit 短哈希不应带进原始日志
    if re.search(r"\d+\.\d+\.\d+\.\d+", rawm + raww):
        fail("输出里含 IP 地址")

    print("OK: 两端脱敏输出一致、字段齐全、无敏感串")


if __name__ == "__main__":
    main()
