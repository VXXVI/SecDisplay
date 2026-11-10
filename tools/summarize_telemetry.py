#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
汇总 telemetry/ 下所有设备的脱敏指标，输出人类可读的一份报告。
我这边 git pull 后跑一次即可，不用逐个文件翻。

用法:
  python3 tools/summarize_telemetry.py [--dir telemetry] [--strict]
  --strict: 缺关键字段 / 坐标两端不一致时以非零码退出（供 CI 用）
"""
import argparse
import glob
import json
import os
import sys

COORD_OK = (1440, 900)


def load_all(root):
    out = []
    for path in sorted(glob.glob(os.path.join(root, "*", "*.json"))):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                doc = json.load(fh)
            out.append((path, doc))
        except Exception as e:
            out.append((path, {"_error": str(e)}))
    return out


def fmt_agg(a):
    if not isinstance(a, dict):
        return "n/a"
    return "中位 {median} / p95 {p95} / 峰 {max}".format(**a)


def show(path, d):
    if "_error" in d:
        print("  !! 解析失败: %s (%s)" % (path, d["_error"]))
        return
    plat = d.get("platform", "?")
    print("\n=== %s  [%s] ===" % (path, d.get("generated_utc", "?")))
    print("  commit=%s  samples=%s" % (d.get("commit", "?"), d.get("samples", 0)))
    c = d.get("coord", {}) or {}
    print("  坐标: 逻辑 %sx%s  物理 %sx%s  来源 %s" % (
        c.get("logical_w"), c.get("logical_h"),
        c.get("physical_w"), c.get("physical_h"), c.get("source", "-")))
    cfg = d.get("config")
    if cfg:
        print("  配置: %sx%s  采集上限 %shz  预设 %s  编码方案 %s" % (
            cfg.get("video_w"), cfg.get("video_h"), cfg.get("capture_hz"),
            cfg.get("preset", "-"), cfg.get("encoder_variant", "-")))
    st = d.get("status")
    if st:
        print("  状态: 呈现 %s  硬解 %s  客户区 %sx%s  全屏 %s" % (
            st.get("present_mode", "-"), st.get("decoder_hw", "-"),
            st.get("client_w"), st.get("client_h"), st.get("fullscreen", "-")))
    m = d.get("metrics", {}) or {}
    if plat == "mac":
        print("  峰值帧率:    " + fmt_agg(m.get("peak_fps")))
        print("  采集延迟ms:  " + fmt_agg(m.get("capture_ms")))
        print("  编码延迟ms:  " + fmt_agg(m.get("encode_ms")))
        print("  码率Mbps:    " + fmt_agg(m.get("mbps")))
        print("  光标包 %s  输入包 %s  丢弃 %s  在途峰 %s" % (
            m.get("cursor_pkts_total"), m.get("input_pkts_total"),
            m.get("dropped_total"), m.get("inflight_max")))
    else:
        print("  解码包 %s  帧 %s  每样本 %s" % (
            m.get("packets_last"), m.get("decoded_last"),
            fmt_agg(m.get("decoded_per_sample"))))
        print("  附加延迟ms:  " + fmt_agg(m.get("extra_latency_ms")))
        print("  码率Mbps:    " + fmt_agg(m.get("mbps")))
        print("  峰值帧率:    " + fmt_agg(m.get("peak_fps")))
        print("  光标包 %s  输入包 %s  解码失败 %s" % (
            m.get("cursor_pkts_total"), m.get("input_pkts_last"),
            m.get("decode_fail_last")))
    w = d.get("warnings", []) or []
    print("  告警: " + (", ".join(w) if w else "无"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="telemetry")
    ap.add_argument("--strict", action="store_true")
    a = ap.parse_args()

    items = load_all(a.dir)
    if not items:
        print("telemetry/ 下还没有任何指标文件。等设备端装好循环任务并运行后会自动出现。")
        return 0

    for path, d in items:
        show(path, d)

    if a.strict:
        problems = []
        for path, d in items:
            if "_error" in d:
                problems.append("%s 解析失败" % path)
                continue
            c = d.get("coord", {}) or {}
            if (c.get("logical_w"), c.get("logical_h")) != COORD_OK:
                problems.append("%s 坐标基准非 %sx%s" % (path, *COORD_OK))
        mac = [d for _, d in items if d.get("platform") == "mac"]
        win = [d for _, d in items if d.get("platform") == "win"]
        if not mac:
            problems.append("缺 Mac 指标")
        if not win:
            problems.append("缺 Windows 指标")
        if problems:
            print("\n[STRICT] 问题:")
            for p in problems:
                print("  - " + p)
            return 2
        print("\n[STRICT] 两端齐全、坐标基准一致（%dx%d）" % COORD_OK)
    return 0


if __name__ == "__main__":
    sys.exit(main())
